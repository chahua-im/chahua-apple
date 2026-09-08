import Foundation
import Darwin

struct EntryRecord: Codable, Sendable {
    var version: Int = 1
    var key: String
    var generation: UUID
    var tags: Set<CacheTag>
    var committedBytes: Int64
    var contentLength: Int64?
    var mimeType: String?
    var etag: String?
    var lastModified: String?
    var freshUntil: Date
    var lastAccess: Date
    var retained: Bool

    var complete: Bool {
        contentLength == committedBytes
    }

    var cachedBytes: Int64 { committedBytes }
}

/// Only the queue-confined storage object owns descriptors. Records remain caller-owned values;
/// generation invalidation, admission, leases, and logical publication belong to MediaCache.
final class CacheDiskStore: Sendable {
    private let directory: URL
    private let storage: DiskStorage

    init(configuration: CacheConfiguration) async throws {
        guard configuration.directory.isFileURL,
              configuration.directory.path.hasPrefix("/"),
              configuration.directory.standardizedFileURL.path != "/",
              configuration.maximumDiskBytes >= 0 else {
            throw MediaCacheError.invalidConfiguration
        }
        directory = configuration.directory.standardizedFileURL
        storage = DiskStorage()
        try await storage.perform { try $0.open(directory: configuration.directory.standardizedFileURL) }
    }

    /// Startup recovery only. Live transient generations must instead use validate(record:).
    func recover() async throws -> [EntryRecord] {
        try await storage.perform { try $0.recover() }
    }

    func create(record: EntryRecord) async throws -> URL {
        try await storage.perform { try $0.create(record: record) }
        return payloadURL(for: record)
    }

    func persist(record: EntryRecord) async throws {
        try await storage.perform { try $0.persist(record: record) }
    }

    func write(record: EntryRecord, offset: Int64, data: Data) async throws -> EntryRecord {
        try await storage.perform { try $0.write(record: record, offset: offset, data: data) }
    }

    /// Returns false after removing a missing/corrupt generation; filesystem failures still throw.
    func validate(record: EntryRecord) async throws -> Bool {
        try await storage.perform { try $0.validate(record: record) }
    }

    func remove(record: EntryRecord) async throws {
        try await storage.perform { try $0.remove(record: record) }
    }

    func allocations() async throws -> (entries: [UUID: Int64], overhead: Int64) {
        try await storage.perform { try $0.allocations() }
    }

    func payloadURL(for record: EntryRecord) -> URL {
        directory.appendingPathComponent("v1/entries", isDirectory: true)
            .appendingPathComponent(record.key, isDirectory: true)
            .appendingPathComponent(record.generation.uuidString, isDirectory: true)
            .appendingPathComponent("payload", isDirectory: false)
    }

    func close() async {
        await storage.close()
    }
}

private struct StoredIdentity: Codable {
    var version: Int
    var key: String
    var generation: UUID
    var retained: Bool

    init(_ record: EntryRecord) {
        version = record.version
        key = record.key
        generation = record.generation
        retained = record.retained
    }
}

/// The unchecked bridge is restricted to this private descriptor owner. Every operation, including
/// open/close, runs on queue. Enqueued closures retain it, so deinit cannot race queued work.
private final class DiskStorage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.chahua.media-cache.disk", qos: .utility)
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var rootFD: Int32 = -1
    private var versionFD: Int32 = -1
    private var entriesFD: Int32 = -1
    private var trashFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var rootURL: URL?
    private var closed = false
    // Transient metadata contains only a recovery marker; durable byte counts stay in memory.
    private var transientCommits: [UUID: (key: String, bytes: Int64)] = [:]

    deinit { closeDescriptors() }

    func perform<T: Sendable>(_ operation: @escaping @Sendable (DiskStorage) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !closed else { throw MediaCacheError.closed }
                    continuation.resume(returning: try operation(self))
                } catch is CorruptEntry {
                    continuation.resume(throwing: MediaCacheError.storageFailure)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closed = true
                closeDescriptors()
                continuation.resume()
            }
        }
    }

    func open(directory: URL) throws {
        // Ancestors are outside cache ownership (for example, the system /var symlink).
        // The configured root itself and every descendant are opened without following links.
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Darwin.mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw posixError() }
        rootFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw posixError() }
        rootURL = directory
        do {
            lockFD = try openFile(rootFD, "owner.lock", flags: O_RDWR | O_CREAT)
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw posixError() }
            versionFD = try ensureDirectory(rootFD, "v1")
            entriesFD = try ensureDirectory(versionFD, "entries")
            trashFD = try ensureDirectory(versionFD, "trash")
            try synchronize(rootFD)
        } catch {
            closeDescriptors()
            throw error
        }
    }

    func recover() throws -> [EntryRecord] {
        try checkRoot()
        try cleanChildren(rootFD, keeping: ["owner.lock", "v1"])
        try cleanChildren(versionFD, keeping: ["entries", "trash"])
        try cleanChildren(trashFD, keeping: [])
        var records: [EntryRecord] = []
        for key in try children(entriesFD) {
            guard validKey(key), let keyFD = try directoryIfPresent(entriesFD, key) else {
                try deleteTree(entriesFD, key)
                continue
            }
            defer { Darwin.close(keyFD) }
            for generationName in try children(keyFD) {
                guard let generation = UUID(uuidString: generationName), generation.uuidString == generationName,
                      let generationFD = try directoryIfPresent(keyFD, generationName) else {
                    try discard(keyFD: keyFD, generationName: generationName)
                    continue
                }
                defer { Darwin.close(generationFD) }
                do {
                    guard let record = try loadRecord(generationFD, key: key, generation: generation),
                          record.complete else {
                        throw CorruptEntry.invalid
                    }
                    let payloadFD = try openPayload(generationFD, record: record, flags: O_RDONLY)
                    Darwin.close(payloadFD)
                    try cleanChildren(generationFD, keeping: ["payload", "metadata.json"])
                    records.append(record)
                } catch is CorruptEntry {
                    try discard(keyFD: keyFD, generationName: generationName)
                }
            }
            try removeEmptyKey(key)
        }
        try synchronize(entriesFD)
        // No index pointer selects a winner after an ambiguous recovery. Discard every conflicting
        // generation rather than choosing a possibly older representation by an incidental timestamp.
        let keyCounts = Dictionary(grouping: records, by: \.key).mapValues(\.count)
        let generationCounts = Dictionary(grouping: records, by: \.generation).mapValues(\.count)
        var recovered: [EntryRecord] = []
        for record in records {
            if keyCounts[record.key] == 1, generationCounts[record.generation] == 1 {
                recovered.append(record)
            } else {
                try remove(record: record)
            }
        }
        return recovered
    }

    func create(record: EntryRecord) throws {
        try checkRoot()
        try validateShape(record)
        guard record.committedBytes == 0 else { throw MediaCacheError.storageFailure }
        let keyFD = try ensureDirectory(entriesFD, record.key)
        defer { Darwin.close(keyFD) }
        let name = record.generation.uuidString
        guard mkdirat(keyFD, name, 0o700) == 0 else { throw posixError() }
        do {
            let generationFD = try openDirectory(keyFD, name)
            defer { Darwin.close(generationFD) }
            let payloadFD = try openFile(generationFD, "payload", flags: O_RDWR | O_CREAT | O_EXCL)
            defer { Darwin.close(payloadFD) }
            try synchronize(payloadFD)
            try replaceMetadata(record, directoryFD: generationFD)
            try synchronize(keyFD)
            rememberTransientCommit(record)
        } catch {
            // If reclamation fails, keep the orphan accounted and surface that failure.
            try discard(keyFD: keyFD, generationName: name)
            throw error
        }
    }

    func persist(record: EntryRecord) throws {
        try checkRoot()
        try validateShape(record)
        try withGeneration(record) { generationFD in
            try checkCommit(record, directoryFD: generationFD)
            let payloadFD = try openPayload(generationFD, record: record, flags: O_RDWR)
            defer { Darwin.close(payloadFD) }
            try synchronize(payloadFD)
            try replaceMetadata(record, directoryFD: generationFD)
            rememberTransientCommit(record)
        }
    }

    func write(record: EntryRecord, offset: Int64, data: Data) throws -> EntryRecord {
        try checkRoot()
        try validateShape(record)
        guard data.count <= 1_048_576, offset == record.committedBytes else {
            throw MediaCacheError.invalidResponse
        }
        let (end, overflow) = offset.addingReportingOverflow(Int64(data.count))
        guard !overflow, record.contentLength.map({ end <= $0 }) ?? true else {
            throw MediaCacheError.invalidResponse
        }
        var updated = record
        updated.committedBytes = end
        try withGeneration(record) { generationFD in
            try checkCommit(record, directoryFD: generationFD)
            let payloadFD = try openPayload(generationFD, record: record, flags: O_RDWR)
            defer { Darwin.close(payloadFD) }
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = pwrite(payloadFD, bytes.baseAddress!.advanced(by: written), bytes.count - written, offset + Int64(written))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw posixError() }
                    written += count
                }
            }
            // A crash may leave unadvertised bytes, but metadata can never advertise undurable bytes.
            try synchronize(payloadFD)
            try replaceMetadata(updated, directoryFD: generationFD)
            rememberTransientCommit(updated)
        }
        return updated
    }

    func validate(record: EntryRecord) throws -> Bool {
        try checkRoot()
        try validateShape(record)
        do {
            try withGeneration(record) { generationFD in
                let stored = try loadRecord(generationFD, key: record.key, generation: record.generation)
                guard (stored != nil) == record.retained else { throw CorruptEntry.invalid }
                if let stored {
                    guard stored.committedBytes == record.committedBytes, stored.contentLength == record.contentLength else {
                        throw CorruptEntry.invalid
                    }
                } else {
                    guard let commit = transientCommits[record.generation],
                          commit.key == record.key, commit.bytes == record.committedBytes else {
                        throw CorruptEntry.invalid
                    }
                }
                let fd = try openPayload(generationFD, record: record, flags: O_RDONLY)
                Darwin.close(fd)
            }
            return true
        } catch is CorruptEntry {
            try remove(record: record)
            return false
        } catch MediaCacheError.missingEntry {
            try remove(record: record)
            return false
        }
    }

    func remove(record: EntryRecord) throws {
        try checkRoot()
        guard validKey(record.key) else { throw MediaCacheError.storageFailure }
        defer { transientCommits.removeValue(forKey: record.generation) }
        guard let keyFD = try directoryIfPresent(entriesFD, record.key) else {
            try deleteTree(entriesFD, record.key)
            try synchronize(entriesFD)
            return
        }
        defer { Darwin.close(keyFD) }
        try discard(keyFD: keyFD, generationName: record.generation.uuidString)
        try removeEmptyKey(record.key)
    }

    func allocations() throws -> (entries: [UUID: Int64], overhead: Int64) {
        try checkRoot()
        var entries: [UUID: Int64] = [:]
        var owners: [UUID: String] = [:]
        var duplicates: Set<UUID> = []
        var path: [String] = []
        let total = try allocatedTree(rootFD, path: &path, entries: &entries, owners: &owners, duplicates: &duplicates)
        for generation in duplicates { entries.removeValue(forKey: generation) }
        let attributable = try entries.values.reduce(Int64(0)) { try checkedAdd($0, $1) }
        return (entries, total - attributable)
    }

    private func allocatedTree(
        _ directoryFD: Int32, path: inout [String], entries: inout [UUID: Int64],
        owners: inout [UUID: String], duplicates: inout Set<UUID>
    ) throws -> Int64 {
        var total = try allocatedBytes(try descriptorStat(directoryFD))
        for name in try children(directoryFD) {
            guard let info = try itemStat(directoryFD, name) else { continue }
            path.append(name)
            defer { path.removeLast() }
            if isDirectory(info) {
                let fd = try openDirectory(directoryFD, name)
                defer { Darwin.close(fd) }
                total = try checkedAdd(total, allocatedTree(fd, path: &path, entries: &entries, owners: &owners, duplicates: &duplicates))
            } else {
                let bytes = try allocatedBytes(info)
                total = try checkedAdd(total, bytes)
                if path.count == 5, path[0] == "v1", path[1] == "entries", validKey(path[2]),
                   let generation = UUID(uuidString: path[3]), generation.uuidString == path[3],
                   name == "payload" || name == "metadata.json", isRegular(info), info.st_nlink == 1 {
                    if let key = owners[generation], key != path[2] { duplicates.insert(generation) }
                    owners[generation] = path[2]
                    entries[generation] = try checkedAdd(entries[generation, default: 0], bytes)
                }
            }
        }
        return total
    }

    private func withGeneration<T>(_ record: EntryRecord, _ body: (Int32) throws -> T) throws -> T {
        guard let keyFD = try directoryIfPresent(entriesFD, record.key) else { throw MediaCacheError.missingEntry }
        defer { Darwin.close(keyFD) }
        guard let generationFD = try directoryIfPresent(keyFD, record.generation.uuidString) else {
            throw MediaCacheError.missingEntry
        }
        defer { Darwin.close(generationFD) }
        return try body(generationFD)
    }

    private func checkCommit(_ record: EntryRecord, directoryFD: Int32) throws {
        if let stored = try loadRecord(directoryFD, key: record.key, generation: record.generation) {
            guard stored.committedBytes == record.committedBytes else { throw MediaCacheError.storageFailure }
        } else {
            guard let commit = transientCommits[record.generation],
                  commit.key == record.key, commit.bytes == record.committedBytes else {
                throw MediaCacheError.storageFailure
            }
        }
    }

    private func rememberTransientCommit(_ record: EntryRecord) {
        if record.retained {
            transientCommits.removeValue(forKey: record.generation)
        } else {
            transientCommits[record.generation] = (record.key, record.committedBytes)
        }
    }

    /// A nil record is a validated transient recovery marker; its live metadata stays with the actor.
    private func loadRecord(_ fd: Int32, key: String, generation: UUID) throws -> EntryRecord? {
        let data = try metadataData(fd)
        let identity: StoredIdentity
        do { identity = try decoder.decode(StoredIdentity.self, from: data) }
        catch { throw CorruptEntry.invalid }
        guard identity.version == 1, identity.key == key, identity.generation == generation else {
            throw CorruptEntry.invalid
        }
        guard identity.retained else { return nil }
        let record: EntryRecord
        do { record = try decoder.decode(EntryRecord.self, from: data) }
        catch { throw CorruptEntry.invalid }
        do { try validateShape(record) }
        catch { throw CorruptEntry.invalid }
        return record
    }

    private func metadataData(_ directoryFD: Int32) throws -> Data {
        let fd: Int32
        do { fd = try openFile(directoryFD, "metadata.json", flags: O_RDONLY) }
        catch let error as POSIXError where error.code == .ENOENT || error.code == .ELOOP || error.code == .ENOTDIR {
            throw CorruptEntry.invalid
        }
        defer { Darwin.close(fd) }
        let info = try descriptorStat(fd)
        guard info.st_size >= 0, info.st_size <= Int64(Int.max) else { throw CorruptEntry.invalid }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var consumed = 0
            while consumed < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: consumed), bytes.count - consumed)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw posixError() }
                guard count > 0 else { throw CorruptEntry.invalid }
                consumed += count
            }
        }
        return data
    }

    private func openPayload(_ directoryFD: Int32, record: EntryRecord, flags: Int32) throws -> Int32 {
        let fd: Int32
        do { fd = try openFile(directoryFD, "payload", flags: flags) }
        catch let error as POSIXError where error.code == .ENOENT || error.code == .ELOOP || error.code == .ENOTDIR {
            throw CorruptEntry.invalid
        }
        do {
            let info = try descriptorStat(fd)
            guard info.st_size == record.committedBytes else { throw CorruptEntry.invalid }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func replaceMetadata(_ record: EntryRecord, directoryFD: Int32) throws {
        // Transient responses persist only a recovery marker, never their HTTP metadata or tags.
        let data = try record.retained ? encoder.encode(record) : encoder.encode(StoredIdentity(record))
        let temporary = ".metadata-\(UUID().uuidString).tmp"
        let fd = try openFile(directoryFD, temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { Darwin.close(fd) }
        do {
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw posixError() }
                    written += count
                }
            }
            try synchronize(fd)
            guard renameat(directoryFD, temporary, directoryFD, "metadata.json") == 0 else { throw posixError() }
            try synchronize(directoryFD)
        } catch {
            if unlinkat(directoryFD, temporary, 0) != 0, errno != ENOENT { throw posixError() }
            throw error
        }
    }

    private func validateShape(_ record: EntryRecord) throws {
        guard record.version == 1, validKey(record.key), !record.tags.isEmpty,
              record.tags.allSatisfy({ !$0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              record.committedBytes >= 0,
              record.contentLength.map({ $0 >= record.committedBytes }) ?? true,
              record.freshUntil.timeIntervalSinceReferenceDate.isFinite,
              record.lastAccess.timeIntervalSinceReferenceDate.isFinite,
              record.etag.map(validETag) ?? true else {
            throw MediaCacheError.storageFailure
        }
    }

    private func validETag(_ value: String) -> Bool {
        let opaque = value.hasPrefix("W/") ? value.dropFirst(2) : value[...]
        guard opaque.utf8.count >= 2, opaque.first == "\"", opaque.last == "\"" else { return false }
        return opaque.dropFirst().dropLast().utf8.allSatisfy { $0 == 0x21 || ($0 >= 0x23 && $0 != 0x7f) }
    }

    private func validKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func discard(keyFD: Int32, generationName: String) throws {
        guard try itemStat(keyFD, generationName) != nil else { return }
        let destination = UUID().uuidString
        guard renameat(keyFD, generationName, trashFD, destination) == 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        // Both sides of the rename are durable before unlinking. Failure leaves discoverable trash.
        try synchronize(keyFD)
        try synchronize(trashFD)
        try deleteTree(trashFD, destination)
        try synchronize(trashFD)
    }

    private func removeEmptyKey(_ key: String) throws {
        if unlinkat(entriesFD, key, AT_REMOVEDIR) != 0 {
            if errno == ENOTEMPTY || errno == EEXIST || errno == ENOENT { return }
            throw posixError()
        }
        try synchronize(entriesFD)
    }

    private func cleanChildren(_ fd: Int32, keeping: Set<String>) throws {
        for name in try children(fd) where !keeping.contains(name) { try deleteTree(fd, name) }
        try synchronize(fd)
    }

    private func deleteTree(_ parentFD: Int32, _ name: String) throws {
        guard let info = try itemStat(parentFD, name) else { return }
        if isDirectory(info) {
            let fd = try openDirectory(parentFD, name)
            do {
                for child in try children(fd) { try deleteTree(fd, child) }
            } catch {
                Darwin.close(fd)
                throw error
            }
            Darwin.close(fd)
            if unlinkat(parentFD, name, AT_REMOVEDIR) != 0, errno != ENOENT { throw posixError() }
        } else if unlinkat(parentFD, name, 0) != 0, errno != ENOENT {
            throw posixError()
        }
    }

    private func children(_ fd: Int32) throws -> [String] {
        // openat(".") gets an independent directory cursor; dup would share the caller's offset.
        let iteratorFD = try openDirectory(fd, ".")
        guard let iterator = fdopendir(iteratorFD) else {
            let error = posixError()
            Darwin.close(iteratorFD)
            throw error
        }
        defer { closedir(iterator) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(iterator) else {
                guard errno == 0 else { throw posixError() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw MediaCacheError.storageFailure }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
    }

    private func ensureDirectory(_ parentFD: Int32, _ name: String) throws -> Int32 {
        if mkdirat(parentFD, name, 0o700) != 0 {
            guard errno == EEXIST else { throw posixError() }
        } else {
            try synchronize(parentFD)
        }
        return try openDirectory(parentFD, name)
    }

    private func directoryIfPresent(_ parentFD: Int32, _ name: String) throws -> Int32? {
        guard let info = try itemStat(parentFD, name), isDirectory(info) else { return nil }
        do { return try openDirectory(parentFD, name) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
    }

    private func openDirectory(_ parentFD: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        return fd
    }

    private func openFile(_ parentFD: Int32, _ name: String, flags: Int32) throws -> Int32 {
        if let existing = try itemStat(parentFD, name) {
            guard isRegular(existing), existing.st_nlink == 1 else { throw CorruptEntry.invalid }
        }
        let fd = openat(parentFD, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw posixError() }
        do {
            let info = try descriptorStat(fd)
            guard isRegular(info), info.st_nlink == 1 else { throw CorruptEntry.invalid }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func checkRoot() throws {
        guard rootFD >= 0, let rootURL else { throw MediaCacheError.closed }
        var info = stat()
        guard lstat(rootURL.path, &info) == 0 else { throw posixError() }
        let root = try descriptorStat(rootFD)
        guard isDirectory(info), info.st_dev == root.st_dev, info.st_ino == root.st_ino else {
            throw MediaCacheError.storageFailure
        }
        for (parent, name, fd) in [(rootFD, "v1", versionFD), (versionFD, "entries", entriesFD), (versionFD, "trash", trashFD), (rootFD, "owner.lock", lockFD)] {
            guard let current = try itemStat(parent, name) else { throw MediaCacheError.storageFailure }
            let opened = try descriptorStat(fd)
            guard current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
                throw MediaCacheError.storageFailure
            }
        }
    }

    private func descriptorStat(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw posixError() }
        return value
    }

    private func itemStat(_ parentFD: Int32, _ name: String) throws -> stat? {
        var value = stat()
        guard fstatat(parentFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        return value
    }

    private func isDirectory(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFDIR }
    private func isRegular(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFREG }

    private func allocatedBytes(_ value: stat) throws -> Int64 {
        let (bytes, overflow) = Int64(value.st_blocks).multipliedReportingOverflow(by: 512)
        guard !overflow, bytes >= 0 else { throw MediaCacheError.storageFailure }
        return bytes
    }

    private func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw MediaCacheError.storageFailure }
        return sum
    }

    private func synchronize(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            if errno != EINTR { throw posixError() }
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func closeDescriptors() {
        for fd in [trashFD, entriesFD, versionFD] where fd >= 0 { Darwin.close(fd) }
        transientCommits.removeAll()
        trashFD = -1
        entriesFD = -1
        versionFD = -1
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
            lockFD = -1
        }
        if rootFD >= 0 { Darwin.close(rootFD); rootFD = -1 }
    }
}

private enum CorruptEntry: Error {
    case invalid
}
