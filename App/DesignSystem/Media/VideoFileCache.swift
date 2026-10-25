import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Byte counts are supplied by URLSession, never by poster extraction or playback buffering.
nonisolated struct VideoDownloadProgress: Sendable {
    let receivedBytes: Int64
    let expectedBytes: Int64

    static let indeterminate = Self(receivedBytes: 0, expectedBytes: -1)

    var fraction: Double? {
        guard expectedBytes > 0, receivedBytes >= 0, receivedBytes <= expectedBytes else {
            return nil
        }
        return Double(receivedBytes) / Double(expectedBytes)
    }

    var percentage: Int? { fraction.map { Int($0 * 100) } }
}

/// Keeps the completed file alive until AVPlayer has released its item. Local input files
/// have no cache owner and are neither copied nor removed.
nonisolated final class VideoFileLease: Sendable {
    let url: URL
    private let cache: VideoFileCache?

    fileprivate init(url: URL, cache: VideoFileCache? = nil) {
        self.url = url
        self.cache = cache
    }

    deinit {
        if let cache {
            let name = url.lastPathComponent
            Task { await cache.release(name: name) }
        }
    }
}

/// Account-owned full movies, separate from Kingfisher's poster/image cache. Disk work and
/// bookkeeping run on this actor, not the UI actor; movie bytes never become a Data value.
actor VideoFileCache {
    /// Context-free previews/viewers share a bounded fallback; signed-in composition always
    /// supplies AppMediaContext's account-namespaced instance instead.
    nonisolated static let unscoped = VideoFileCache(
        directory: URL.cachesDirectory.appendingPathComponent("app.chahua.chat.videos.unscoped"))

    private struct File {
        let url: URL
        let size: UInt64
        var accessed: Date
        var leases = 0
        var discard = false
    }

    private struct Consumer {
        let continuation: CheckedContinuation<VideoFileLease, Error>
        let progress: @MainActor @Sendable (VideoDownloadProgress) -> Void
    }

    private struct Download {
        let id: UUID
        let session: URLSession
        let task: URLSessionDownloadTask
        let stagingURL: URL
        let completedURL: URL
        var consumers: [UUID: Consumer]
        var progress = VideoDownloadProgress.indeterminate
        var validation: Task<Void, Never>?
        var discard = false
    }

    private let directory: URL
    private let configuration: URLSessionConfiguration
    private let sizeLimit: UInt64
    private var prepared = false
    private var files: [String: File] = [:]
    private var entries: [String: String] = [:]
    private var downloads: [String: Download] = [:]

    init(
        directory: URL, configuration: URLSessionConfiguration = .default,
        sizeLimit: UInt64 = 512 * 1_024 * 1_024
    ) {
        self.directory = directory
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = configuration
        self.sizeLimit = sizeLimit
    }

    func file(
        for url: URL,
        progress: @escaping @MainActor @Sendable (VideoDownloadProgress) -> Void
    ) async throws -> VideoFileLease {
        try Task.checkCancellation()
        if url.isFileURL { return VideoFileLease(url: url) }
        try prepare()
        let key = Self.key(for: url)
        if let name = entries[key], var file = files[name], !file.discard,
            FileManager.default.fileExists(atPath: file.url.path)
        {
            file.leases += 1
            file.accessed = Date()
            files[name] = file
            try? FileManager.default.setAttributes(
                [.modificationDate: file.accessed], ofItemAtPath: file.url.path)
            return VideoFileLease(url: file.url, cache: self)
        }
        let consumerID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let consumer = Consumer(continuation: continuation, progress: progress)
                if var download = downloads[key] {
                    download.consumers[consumerID] = consumer
                    downloads[key] = download
                    let value = download.progress
                    Task { @MainActor in progress(value) }
                    return
                }
                let id = UUID()
                let suffix = url.pathExtension.lowercased()
                let safeSuffix =
                    !suffix.isEmpty && suffix.count <= 10
                        && UTType(filenameExtension: suffix)?.conforms(to: .movie) == true
                    ? suffix : "mp4"
                // AVFoundation needs a movie-typed extension even during preflight.
                let staging = directory.appendingPathComponent(
                    "\(id.uuidString).partial.\(safeSuffix)")
                let completed = directory.appendingPathComponent(
                    "\(key).\(id.uuidString).\(safeSuffix)")
                let delegate = VideoFileDownloadDelegate(
                    cache: self, key: key, id: id, stagingURL: staging)
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(
                    configuration: configuration, delegate: delegate, delegateQueue: queue)
                let task = session.downloadTask(with: url)
                downloads[key] = Download(
                    id: id, session: session, task: task, stagingURL: staging,
                    completedURL: completed, consumers: [consumerID: consumer])
                Task { @MainActor in progress(.indeterminate) }
                task.resume()
            }
        } onCancel: {
            Task { await self.cancel(key: key, consumerID: consumerID) }
        }
    }

    func diskStorageSize() throws -> UInt {
        try prepare()
        return UInt(clamping: files.values.reduce(UInt64(0)) { $0 + $1.size })
    }

    /// Playing files stay pinned; clear removes them as soon as their last player releases
    /// its lease. In-flight consumers may finish, but their result is likewise not retained.
    func clear() throws {
        try prepare()
        entries.removeAll()
        for name in Array(files.keys) {
            if let file = files[name] { try persistDiscard(for: file.url) }
            files[name]?.discard = true
        }
        for key in Array(downloads.keys) {
            if let download = downloads[key] {
                try persistDiscard(for: download.completedURL)
            }
            downloads[key]?.discard = true
        }
        try prune()
    }

    func invalidate(_ lease: VideoFileLease) {
        let name = lease.url.lastPathComponent
        guard files[name] != nil else { return }
        files[name]?.discard = true
        try? persistDiscard(for: lease.url)
        let key = String(name.prefix(64))
        if entries[key] == name { entries.removeValue(forKey: key) }
        try? prune()
    }

    fileprivate func release(name: String) {
        guard var file = files[name] else { return }
        file.leases = max(0, file.leases - 1)
        files[name] = file
        try? prune()
    }

    fileprivate func received(key: String, id: UUID, received: Int64, expected: Int64) {
        guard var download = downloads[key], download.id == id,
            download.validation == nil, received >= download.progress.receivedBytes
        else { return }
        let progress = VideoDownloadProgress(receivedBytes: received, expectedBytes: expected)
        let changed = progress.percentage != download.progress.percentage
        download.progress = progress
        downloads[key] = download
        guard changed else { return }
        for consumer in download.consumers.values {
            Task { @MainActor in consumer.progress(progress) }
        }
    }

    fileprivate func downloaded(
        key: String, id: UUID, stagingURL: URL, response: URLResponse?, error: Error?
    ) {
        guard var download = downloads[key], download.id == id else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }
        download.session.finishTasksAndInvalidate()
        if let error {
            finishFailure(key: key, id: id, error: error)
            return
        }
        do {
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: download.stagingURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let expected = Self.hasIdentityEncoding(response) ? response.expectedContentLength : -1
            guard size > 0, expected <= 0 || size == expected
            else { throw URLError(.cannotDecodeContentData) }
            // URLSession has finished writing, but only a locally playable asset is committed.
            // This is AVFoundation preflight, not a whole-file integrity checksum.
            for consumer in download.consumers.values {
                Task { @MainActor in consumer.progress(.indeterminate) }
            }
            let staging = download.stagingURL
            download.validation = Task { [weak self] in
                let asset = AVURLAsset(url: staging)
                do {
                    let playable = try await withTaskCancellationHandler {
                        try await asset.load(.isPlayable)
                    } onCancel: {
                        asset.cancelLoading()
                    }
                    try Task.checkCancellation()
                    guard playable else { throw URLError(.cannotDecodeContentData) }
                    await self?.commit(key: key, id: id, size: UInt64(size))
                } catch {
                    await self?.finishFailure(key: key, id: id, error: error)
                }
            }
            downloads[key] = download
        } catch {
            finishFailure(key: key, id: id, error: error)
        }
    }

    private func commit(key: String, id: UUID, size: UInt64) {
        guard let download = downloads[key], download.id == id else { return }
        do {
            if download.discard { try persistDiscard(for: download.completedURL) }
            // Same-directory rename makes incomplete/failed files invisible to cache lookups.
            try FileManager.default.moveItem(at: download.stagingURL, to: download.completedURL)
            downloads.removeValue(forKey: key)
            let name = download.completedURL.lastPathComponent
            files[name] = File(
                url: download.completedURL, size: size, accessed: Date(),
                leases: download.consumers.count, discard: download.discard)
            if !download.discard { entries[key] = name }
            for consumer in download.consumers.values {
                consumer.continuation.resume(
                    returning: VideoFileLease(url: download.completedURL, cache: self))
            }
            try? prune()
        } catch {
            finishFailure(key: key, id: id, error: error)
        }
    }

    private func finishFailure(key: String, id: UUID, error: Error) {
        guard let download = downloads[key], download.id == id else { return }
        downloads.removeValue(forKey: key)
        download.task.cancel()
        download.session.invalidateAndCancel()
        download.validation?.cancel()
        try? FileManager.default.removeItem(at: download.stagingURL)
        for consumer in download.consumers.values {
            consumer.continuation.resume(throwing: error)
        }
    }

    private func cancel(key: String, consumerID: UUID) {
        guard var download = downloads[key],
            let consumer = download.consumers.removeValue(forKey: consumerID)
        else { return }
        downloads[key] = download
        consumer.continuation.resume(throwing: CancellationError())
        if download.consumers.isEmpty {
            finishFailure(key: key, id: download.id, error: CancellationError())
        }
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !prepared else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        // A clear/invalidation may leave a playing file pinned until process exit.
        // Honor its durable discard marker before rebuilding the reusable index.
        var discarded: Set<String> = []
        for marker in urls where marker.pathExtension == "discard" {
            let target = marker.deletingPathExtension()
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.removeItem(at: marker)
            discarded.insert(target.lastPathComponent)
        }
        for url in urls {
            if url.pathExtension == "discard" || discarded.contains(url.lastPathComponent) {
                continue
            }
            let parts = url.lastPathComponent.split(separator: ".")
            if url.pathExtension == "partial"
                || (parts.count == 3 && parts[1] == "partial"
                    && UUID(uuidString: String(parts[0])) != nil)
            {
                try FileManager.default.removeItem(at: url)
                continue
            }
            guard parts.count == 3, parts[0].count == 64,
                UUID(uuidString: String(parts[1])) != nil
            else { continue }
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ])
            let name = url.lastPathComponent
            let key = String(parts[0])
            let accessed = values.contentModificationDate ?? .distantPast
            files[name] = File(
                url: url, size: UInt64(max(0, values.fileSize ?? 0)), accessed: accessed)
            if let existing = entries[key], let previous = files[existing],
                previous.accessed >= accessed
            {
                files[name]?.discard = true
            } else {
                if let existing = entries[key] { files[existing]?.discard = true }
                entries[key] = name
            }
        }
        prepared = true
        try prune()
    }

    private func prune() throws {
        var size = files.values.reduce(UInt64(0)) { $0 + $1.size }
        guard size > sizeLimit || files.values.contains(where: { $0.discard && $0.leases == 0 })
        else { return }
        for (name, file) in files.sorted(by: { $0.value.accessed < $1.value.accessed }) {
            guard file.leases == 0, file.discard || size > sizeLimit else { continue }
            if FileManager.default.fileExists(atPath: file.url.path) {
                try FileManager.default.removeItem(at: file.url)
            }
            let marker = file.url.appendingPathExtension("discard")
            if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker)
            }
            files.removeValue(forKey: name)
            let key = String(name.prefix(64))
            if entries[key] == name { entries.removeValue(forKey: key) }
            size -= file.size
        }
    }

    private func persistDiscard(for url: URL) throws {
        let marker = url.appendingPathExtension("discard")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data().write(to: marker, options: .atomic)
        }
    }

    nonisolated fileprivate static func hasIdentityEncoding(_ response: HTTPURLResponse) -> Bool {
        guard let encoding = response.value(forHTTPHeaderField: "Content-Encoding") else {
            return true
        }
        let normalized = encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "identity"
    }

    private static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Mutable delegate state is confined to its single-operation URLSession delegate queue.
/// Moving the system temporary file must happen synchronously before didFinish returns.
nonisolated private final class VideoFileDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private weak var cache: VideoFileCache?
    private let key: String
    private let id: UUID
    private let stagingURL: URL
    private var stagingError: Error?

    init(cache: VideoFileCache, key: String, id: UUID, stagingURL: URL) {
        self.cache = cache
        self.key = key
        self.id = id
        self.stagingURL = stagingURL
    }

    private var identityEncoding: Bool?

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if identityEncoding == nil, let response = downloadTask.response as? HTTPURLResponse {
            identityEncoding = VideoFileCache.hasIdentityEncoding(response)
        }
        let expected = identityEncoding == false ? -1 : totalBytesExpectedToWrite
        Task { [weak cache, key, id] in
            await cache?.received(
                key: key, id: id, received: totalBytesWritten,
                expected: expected)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
        } catch {
            stagingError = error
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        let failure = error ?? stagingError
        let response = task.response
        Task { [weak cache, key, id, stagingURL] in
            if let cache {
                await cache.downloaded(
                    key: key, id: id, stagingURL: stagingURL, response: response, error: failure)
            } else {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }
    }
}
