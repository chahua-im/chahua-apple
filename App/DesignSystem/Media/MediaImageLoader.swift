import ChahuaMediaCache
import Foundation
import Nuke
import os

@MainActor
final class MediaImageLoader {
    private let cache: MediaCache
    private let pipeline: ImagePipeline
    private let imageCache: ImageCache
    private var isClosed = false
    private let logger = Logger(subsystem: "app.chahua.chat", category: "media-images")
    private let traceLoaderID: UUID? = AvatarCacheTrace.enabled ? UUID() : nil

    init(cache: MediaCache) {
        self.cache = cache
        let imageCache = ImageCache(costLimit: 67_108_864)
        self.imageCache = imageCache

        let session = URLSessionConfiguration.ephemeral
        session.urlCache = nil
        session.httpCookieStorage = nil
        session.httpShouldSetCookies = false
        session.urlCredentialStorage = nil
        session.requestCachePolicy = .reloadIgnoringLocalCacheData
        var configuration = ImagePipeline.Configuration(dataLoader: DataLoader(configuration: session))
        configuration.imageCache = imageCache
        configuration.dataCache = nil
        configuration.isResumableDataEnabled = false
        pipeline = ImagePipeline(configuration: configuration)
        if let traceLoaderID {
            AvatarCacheTrace.event("image_loader_created loader=\(traceLoaderID.uuidString) memory_limit=\(imageCache.costLimit) count_limit=\(imageCache.countLimit) ttl_s=\(imageCache.ttl.map { String($0) } ?? "none") entry_cost_fraction=\(imageCache.entryCostLimit)")
        }
    }

    /// A memory-only first frame, including eligible expired content.
    func cachedImage(for request: MediaRequest, thumbnailPixelSize: CGSize? = nil) -> ImageResponse? {
        // SwiftUI can evaluate the presentation lookup repeatedly; trace only the task's real lookup.
        let trace = !AvatarCacheTrace.enabled || AvatarCacheTrace.load == nil ? nil : traceDetails(for: request, thumbnailPixelSize: thumbnailPixelSize)
        let started: ContinuousClock.Instant? = trace == nil ? nil : .now
        var outcome = "metadata-rejected"
        defer {
            if let trace, let started {
                AvatarCacheTrace.event("image_sync_lookup \(trace) outcome=\(outcome) ms=\(AvatarCacheTrace.milliseconds(since: started)) memory_count=\(imageCache.totalCount) memory_cost=\(imageCache.totalCost) memory_limit=\(imageCache.costLimit)")
            }
        }
        guard !isClosed else {
            outcome = "closed"
            return nil
        }
        guard let identifier = cache.cachedContentIdentifier(for: request, allowingStale: true) else { return nil }
        var imageRequest = makeImageRequest(url: nil, thumbnailPixelSize: thumbnailPixelSize)
        imageRequest.imageID = identifier
        guard let container = pipeline.cache.cachedImage(for: imageRequest, caches: [.memory]) else {
            outcome = "decoded-miss"
            return nil
        }
        outcome = "decoded-hit"
        return ImageResponse(container: container, request: imageRequest, cacheType: .memory)
    }

    /// Emits a validated cached image before waiting for the normal freshness acquisition.
    /// A refresh error is still thrown so presentation can retain only its valid first frame.
    func image(
        for request: MediaRequest,
        thumbnailPixelSize: CGSize? = nil,
        onCachedImage: @MainActor (ImageResponse) -> Void
    ) async throws -> ImageResponse {
        try Task.checkCancellation()
        guard !isClosed else { throw MediaCacheError.closed }
        do {
            if let file = try await cache.cachedFile(for: request, allowingStale: true) {
                let response = try await decode(file, thumbnailPixelSize: thumbnailPixelSize)
                // Decoding and lease release suspend. Never emit a generation revoked meanwhile.
                if cache.cachedContentIdentifier(for: request, allowingStale: true) == file.url.absoluteString {
                    onCachedImage(response)
                }
            }
        } catch {
            try Task.checkCancellation()
            guard !isClosed else { throw MediaCacheError.closed }
            // A missing/corrupt cached image is not a reason to skip the normal repair/load.
        }
        return try await image(for: request, thumbnailPixelSize: thumbnailPixelSize)
    }

    func image(for request: MediaRequest, thumbnailPixelSize: CGSize? = nil) async throws -> ImageResponse {
        let trace = traceDetails(for: request, thumbnailPixelSize: thumbnailPixelSize)
        let started: ContinuousClock.Instant? = trace == nil ? nil : .now
        var outcome = "error"
        var stage = "admission"
        defer {
            if let trace, let started {
                AvatarCacheTrace.event("image_load_end \(trace) outcome=\(Task.isCancelled ? "cancelled" : outcome) stage=\(stage) ms=\(AvatarCacheTrace.milliseconds(since: started)) memory_count=\(imageCache.totalCount) memory_cost=\(imageCache.totalCost)")
            }
        }
        if let trace {
            AvatarCacheTrace.event("image_load_start \(trace)")
        }
        try Task.checkCancellation()
        guard !isClosed else { throw MediaCacheError.closed }
        let loadID = UUID()

        // Even decoded-memory hits must register tags and acquire the current generation.
        let file: CachedFile
        stage = "file-acquisition"
        let fileStarted: ContinuousClock.Instant? = trace == nil ? nil : .now
        if let trace {
            AvatarCacheTrace.event("image_file_start \(trace)")
        }
        do {
            file = try await cache.file(for: request)
            if let trace, let fileStarted {
                AvatarCacheTrace.event("image_file_end \(trace) outcome=success ms=\(AvatarCacheTrace.milliseconds(since: fileStarted))")
            }
        } catch let error as CancellationError {
            outcome = "cancelled"
            if let trace, let fileStarted {
                AvatarCacheTrace.event("image_file_end \(trace) outcome=cancelled ms=\(AvatarCacheTrace.milliseconds(since: fileStarted))")
            }
            throw error
        } catch {
            let cancelled = trace != nil && (Task.isCancelled || (error as? URLError)?.code == .cancelled)
            outcome = cancelled ? "cancelled" : "error"
            if let trace, let fileStarted {
                AvatarCacheTrace.event("image_file_end \(trace) outcome=\(outcome) ms=\(AvatarCacheTrace.milliseconds(since: fileStarted))")
            }
            if !cancelled {
                logger.debug("file-failed load=\(loadID, privacy: .public) cacheError=\(String(describing: error as? MediaCacheError), privacy: .public) domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            }
            throw error
        }
        stage = "decode"
        let response = try await decode(file, thumbnailPixelSize: thumbnailPixelSize, trace: trace)
        outcome = "success"
        stage = "return"
        return response
    }

    private func decode(
        _ file: CachedFile, thumbnailPixelSize: CGSize?, trace: String? = nil
    ) async throws -> ImageResponse {
        var stage = "nuke"
        var stepStarted: ContinuousClock.Instant? = nil
        do {
            try Task.checkCancellation()
            guard !isClosed else { throw MediaCacheError.closed }
            let imageRequest = makeImageRequest(url: file.url, thumbnailPixelSize: thumbnailPixelSize)
            stage = "nuke"
            stepStarted = trace == nil ? nil : .now
            if let trace {
                AvatarCacheTrace.event("image_nuke_start \(trace)")
            }
            let response = try await pipeline.imageTask(with: imageRequest).response
            if let trace, let stepStarted {
                let source: String
                switch response.cacheType {
                case .memory: source = "memory"
                case .disk: source = "disk"
                case nil: source = "local-file"
                }
                AvatarCacheTrace.event("image_nuke_end \(trace) outcome=success source=\(source) ms=\(AvatarCacheTrace.milliseconds(since: stepStarted))")
            }
            stepStarted = nil
            try Task.checkCancellation()
            guard !isClosed else { throw MediaCacheError.closed }
            stage = "lease-validation"
            stepStarted = trace == nil ? nil : .now
            if let trace {
                AvatarCacheTrace.event("image_lease_validation_start \(trace)")
            }
            try await file.checkValidity()
            if let trace, let stepStarted {
                AvatarCacheTrace.event("image_lease_validation_end \(trace) outcome=valid ms=\(AvatarCacheTrace.milliseconds(since: stepStarted))")
            }
            stage = "lease-release"
            stepStarted = trace == nil ? nil : .now
            if let trace {
                AvatarCacheTrace.event("image_lease_release_start \(trace) path=success")
            }
            await file.release()
            if let trace, let stepStarted {
                AvatarCacheTrace.event("image_lease_release_end \(trace) path=success ms=\(AvatarCacheTrace.milliseconds(since: stepStarted))")
            }
            stepStarted = nil
            stage = "return"
            try Task.checkCancellation()
            guard !isClosed else { throw MediaCacheError.closed }
            return response
        } catch {
            if let trace {
                let outcome = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled ? "cancelled" : "error"
                if let stepStarted {
                    AvatarCacheTrace.event("image_step_end \(trace) stage=\(stage) outcome=\(outcome) ms=\(AvatarCacheTrace.milliseconds(since: stepStarted))")
                }
                AvatarCacheTrace.event("image_lease_release_start \(trace) path=cleanup")
            }
            let releaseStarted: ContinuousClock.Instant? = trace == nil ? nil : .now
            await file.release()
            if let trace, let releaseStarted {
                AvatarCacheTrace.event("image_lease_release_end \(trace) path=cleanup ms=\(AvatarCacheTrace.milliseconds(since: releaseStarted))")
            }
            try Task.checkCancellation()
            guard !isClosed else { throw MediaCacheError.closed }
            throw error
        }
    }

    private func makeImageRequest(url: URL?, thumbnailPixelSize: CGSize?) -> ImageRequest {
        var request = ImageRequest(url: url, options: [.disableDiskCache])
        if let thumbnailPixelSize {
            request.thumbnail = ImageRequest.ThumbnailOptions(
                size: thumbnailPixelSize,
                unit: .pixels,
                contentMode: .aspectFill
            )
        }
        return request
    }

    private func traceDetails(for request: MediaRequest, thumbnailPixelSize: CGSize?) -> String? {
        guard let traceLoaderID, let key = AvatarCacheTrace.key(for: request) else { return nil }
        let thumbnail: String
        if let thumbnailPixelSize {
            thumbnail = "\(thumbnailPixelSize.width)x\(thumbnailPixelSize.height)"
        } else {
            thumbnail = "full"
        }
        return "loader=\(traceLoaderID.uuidString) key=\(key) thumbnail=\(thumbnail)"
    }

    func close() {
        guard !isClosed else { return }
        if let traceLoaderID {
            AvatarCacheTrace.event("image_loader_close loader=\(traceLoaderID.uuidString) memory_count=\(imageCache.totalCount) memory_cost=\(imageCache.totalCost)")
        }
        isClosed = true
        pipeline.invalidate()
        imageCache.removeAll()
    }
}
