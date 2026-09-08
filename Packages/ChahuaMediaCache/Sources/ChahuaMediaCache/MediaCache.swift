import Foundation
import os

/// The single owner of raw image files, HTTP work, tags, and revocable file leases.
public actor MediaCache {
    private final class Entry {
        var record: EntryRecord
        var durableRecord: EntryRecord?
        // Admissions can add tags while a disk operation is suspended. Only the disk
        // gate mutates record; flushTags commits this separate logical union before delivery.
        var tags: Set<CacheTag>
        var valid = true
        var stored: Bool
        var ready: Bool
        var request: URLRequest?
        var previous: UUID?
        var conditional = false
        var response: HTTPRepresentation?
        var notModified = false
        var waiters: Set<UUID> = []
        var leases: Set<UUID> = []
        var work: Task<Void, Never>?

        init(record: EntryRecord, stored: Bool, ready: Bool, request: URLRequest? = nil) {
            self.record = record
            durableRecord = stored ? record : nil
            tags = record.tags
            self.stored = stored
            self.ready = ready
            self.request = request
        }
    }

    private struct Waiter {
        let request: URLRequest
        let key: String
        let tags: Set<CacheTag>
        let continuation: CheckedContinuation<CachedFile, any Error>
        var generation: UUID?
    }

    private let configuration: CacheConfiguration
    private let disk: CacheDiskStore
    private let transport: HTTPMediaTransport
    private let clock: @Sendable () -> Date
    private nonisolated let cachedContents: CachedContentIndex
    private var entries: [UUID: Entry] = [:]
    private var joinable: [String: UUID] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var barriers: [String: Int] = [:]
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var diskLocked = false
    private var diskWaiters: [CheckedContinuation<Void, Never>] = []
    private var reservedBytes: Int64 = 0
    private var closed = false
    private var shutdownTask: Task<Void, any Error>?
    private var storageError: (any Error)? {
        didSet {
            if storageError != nil { cachedContents.close() }
        }
    }
    private let logger = Logger(subsystem: "app.chahua.chat", category: "media-cache")
    private let logID = UUID()

    public init(configuration: CacheConfiguration) async throws {
        try await self.init(configuration: configuration, protocolClasses: [], clock: { Date() })
    }

    init(configuration: CacheConfiguration, protocolClasses: [AnyClass],
         clock: @escaping @Sendable () -> Date) async throws {
        self.configuration = configuration
        self.clock = clock
        cachedContents = CachedContentIndex(clock: clock)
        disk = try await CacheDiskStore(configuration: configuration)
        transport = HTTPMediaTransport(protocolClasses: protocolClasses.isEmpty ? nil : protocolClasses, clock: clock)
        do {
            for record in try await disk.recover() {
                let entry = Entry(record: record, stored: true, ready: true)
                entries[record.generation] = entry
                joinable[record.key] = record.generation
            }
            try await initializeCapacity()
            for entry in entries.values { publishCachedContent(entry) }
            logger.debug("open cache=\(self.logID, privacy: .public) recovered=\(self.entries.count) limit=\(configuration.maximumDiskBytes)")
        } catch {
            logger.debug("open-failed cache=\(self.logID, privacy: .public) domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            await disk.close()
            throw error
        }
    }

    /// An opaque decoded-memory cache key, not a file URL lease. This lookup performs
    /// no IO or tag registration; every load must still acquire and validate `file(for:)`.
    public nonisolated func cachedContentIdentifier(for request: MediaRequest) -> String? {
        guard let normalized = try? request.normalized() else { return nil }
        return cachedContents.identifier(for: normalized.key, tags: request.tags)
    }

    public func file(for request: MediaRequest) async throws -> CachedFile {
        try checkOpen()
        let normalized = try request.normalized()
        let id = UUID()
        logger.debug("request cache=\(self.logID, privacy: .public) key=\(normalized.key, privacy: .public) waiter=\(id, privacy: .public) tags=\(request.tags.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)")
        let file = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CachedFile, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiters[id] = Waiter(request: normalized.request, key: normalized.key, tags: request.tags,
                                     continuation: continuation)
                admit(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        do {
            try Task.checkCancellation()
            try await file.checkValidity()
            return file
        } catch {
            await file.release()
            throw error
        }
    }

    public func addTags(_ tags: Set<CacheTag>, to key: String) async throws {
        try checkOpen()
        try MediaRequest.validate(tags: tags)
        await lockDisk()
        defer { unlockDisk() }
        try checkOpen()
        let selected = entries.values.filter { $0.valid && $0.record.key == key }
        guard !selected.isEmpty else { throw MediaCacheError.missingEntry }
        for entry in selected { entry.tags.formUnion(tags) }
        for entry in selected {
            try requireValid(entry)
            try await ensureStored(entry)
            try await flushTags(entry)
            publishCachedContent(entry)
        }
    }

    public func usage() async throws -> CacheUsage {
        try checkOpen()
        await lockDisk()
        defer { unlockDisk() }
        try checkOpen()
        try await repairEntries()
        let allocation = try await disk.allocations()
        try checkOpen()
        var total = CacheUsageBucket()
        var byTag: [CacheTag: CacheUsageBucket] = [:]
        for entry in entries.values where entry.valid {
            let bytes = allocation.entries[entry.record.generation] ?? 0
            Self.accumulate(entry, allocated: bytes, into: &total)
            for tag in entry.tags {
                var bucket = byTag[tag] ?? CacheUsageBucket()
                Self.accumulate(entry, allocated: bytes, into: &bucket)
                byTag[tag] = bucket
            }
        }
        // Revoked generations awaiting callback drain are no longer items, but their
        // allocations remain owned and must not disappear from accounting.
        let unassigned = allocation.entries.reduce(Int64(0)) { sum, pair in
            sum + (entries[pair.key]?.valid == true ? 0 : pair.value)
        }
        return CacheUsage(total: total, byTag: byTag, overheadDiskBytes: allocation.overhead + unassigned)
    }

    public func remove(tag: CacheTag) async throws -> CacheRemoval {
        try MediaRequest.validate(tags: [tag])
        return try await removeMatching { $0.contains(tag) }
    }

    public func removeAll() async throws -> CacheRemoval {
        try await removeMatching { _ in true }
    }

    public func trim(toDiskBytes bytes: Int64) async throws -> CacheRemoval {
        try checkOpen()
        guard bytes >= 0 else { throw MediaCacheError.invalidConfiguration }
        await lockDisk()
        defer { unlockDisk() }
        try checkOpen()
        try await repairEntries()
        return try await trimLocked(to: bytes)
    }

    public func shutdown(removingFiles: Bool) async throws {
        if let shutdownTask { return try await shutdownTask.value }
        closed = true
        cachedContents.close()
        logger.debug("shutdown cache=\(self.logID, privacy: .public) removingFiles=\(removingFiles) entries=\(self.entries.count) waiters=\(self.waiters.count)")
        let selected = Array(entries.values)
        let discard = selected.filter { removingFiles || !$0.valid || !$0.ready || !$0.record.retained }
        for entry in selected { invalidate(entry, error: MediaCacheError.closed) }
        for id in Array(waiters.keys) { failWaiter(id, error: MediaCacheError.closed) }
        let work = selected.compactMap(\.work)
        let cleanup = Array(cleanupTasks.values)
        let task = Task {
            await self.transport.shutdown()
            for producer in work { await producer.value }
            for pending in cleanup { await pending.value }
            await self.lockDisk()
            var failure: (any Error)?
            for entry in discard {
                do { try await self.disk.remove(record: entry.record) }
                catch { if failure == nil { failure = error } }
            }
            // Closing is unconditional: a failed account purge must never keep its lock.
            await self.disk.close()
            self.entries.removeAll()
            self.joinable.removeAll()
            self.barriers.removeAll()
            self.unlockDisk()
            if let failure { throw failure }
        }
        shutdownTask = task
        try await task.value
    }

    // MARK: Admission and caller lifetimes

    private func admit(_ id: UUID) {
        guard var waiter = waiters[id], waiter.generation == nil else { return }
        guard !closed, storageError == nil else {
            failWaiter(id, error: storageError ?? MediaCacheError.closed)
            return
        }
        guard barriers[waiter.key] == nil else {
            logger.debug("barrier-wait cache=\(self.logID, privacy: .public) key=\(waiter.key, privacy: .public) waiter=\(id, privacy: .public)")
            return
        }
        let entry: Entry
        if let generation = joinable[waiter.key], let existing = entries[generation], existing.valid {
            entry = existing
            logger.debug("lookup cache=\(self.logID, privacy: .public) key=\(waiter.key, privacy: .public) generation=\(generation, privacy: .public) ready=\(existing.ready) producerActive=\(existing.work != nil)")
            entry.tags.formUnion(waiter.tags)
            if entry.request == nil { entry.request = waiter.request }
        } else {
            logger.debug("disk-miss cache=\(self.logID, privacy: .public) key=\(waiter.key, privacy: .public) reason=no-retained-entry")
            entry = makeEntry(key: waiter.key, tags: waiter.tags, request: waiter.request)
        }
        waiter.generation = entry.record.generation
        waiters[id] = waiter
        entry.waiters.insert(id)
        start(entry)
    }

    private func makeEntry(key: String, tags: Set<CacheTag>, request: URLRequest) -> Entry {
        let now = clock()
        if let generation = joinable[key] {
            cachedContents.remove(key: key, generation: generation)
        }
        // An unclassified producer is crash-disposable and visible to category removal
        // before its first disk operation or HTTP callback.
        let record = EntryRecord(key: key, generation: UUID(), tags: tags, committedBytes: 0,
                                 contentLength: nil, mimeType: nil, etag: nil, lastModified: nil,
                                 freshUntil: now, lastAccess: now, retained: false)
        let entry = Entry(record: record, stored: false, ready: false, request: request)
        entries[record.generation] = entry
        joinable[key] = record.generation
        return entry
    }

    private func start(_ entry: Entry) {
        guard entry.work == nil else { return }
        let id = entry.record.generation
        entry.work = Task { await self.produce(id) }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters[id] else { return }
        logger.debug("cancel-waiter cache=\(self.logID, privacy: .public) key=\(waiter.key, privacy: .public) waiter=\(id, privacy: .public)")
        failWaiter(id, error: CancellationError())
        guard let generation = waiter.generation, let entry = entries[generation], entry.valid,
              entry.waiters.isEmpty else { return }
        if !entry.ready {
            invalidate(entry, error: CancellationError())
            scheduleCleanup(entry)
        }
    }

    private func failWaiter(_ id: UUID, error: any Error) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        if let generation = waiter.generation { entries[generation]?.waiters.remove(id) }
        waiter.continuation.resume(throwing: error)
    }

    private func deliver(_ entry: Entry) throws {
        try requireValid(entry)
        guard entry.ready, entry.record.complete else { throw MediaCacheError.invalidResponse }
        publishCachedContent(entry)
        logger.debug("deliver cache=\(self.logID, privacy: .public) key=\(entry.record.key, privacy: .public) generation=\(entry.record.generation, privacy: .public) bytes=\(entry.record.committedBytes) retained=\(entry.record.retained) waiters=\(entry.waiters.count)")
        for id in entry.waiters {
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            let lease = UUID()
            let generation = entry.record.generation
            entry.leases.insert(lease)
            let file = CachedFile(url: disk.payloadURL(for: entry.record), key: entry.record.key,
                                  validate: { try await self.validateLease(lease, generation: generation) },
                                  release: { await self.releaseLease(lease, generation: generation) })
            waiter.continuation.resume(returning: file)
        }
        entry.waiters.removeAll()
        entry.request = nil
    }

    private func publishCachedContent(_ entry: Entry) {
        guard !closed, storageError == nil, entry.valid, entry.stored, entry.ready,
              entry.record.retained, entry.record.complete,
              joinable[entry.record.key] == entry.record.generation,
              let record = entry.durableRecord, record.retained, record.complete else {
            cachedContents.remove(key: entry.record.key, generation: entry.record.generation)
            return
        }
        cachedContents.publish(.init(generation: record.generation,
                                     identifier: disk.payloadURL(for: record).absoluteString,
                                     tags: record.tags, freshUntil: record.freshUntil), for: record.key)
    }

    private func validateLease(_ lease: UUID, generation: UUID) throws {
        guard !closed else { throw MediaCacheError.closed }
        guard let entry = entries[generation], entry.valid, entry.leases.contains(lease) else {
            throw MediaCacheError.invalidated
        }
    }

    private func releaseLease(_ lease: UUID, generation: UUID) async {
        guard let entry = entries[generation] else { return }
        entry.leases.remove(lease)
        if entry.valid, !entry.record.retained, entry.leases.isEmpty, entry.waiters.isEmpty,
           !entries.values.contains(where: { $0.valid && $0.previous == generation }) {
            invalidate(entry, error: MediaCacheError.invalidated)
            logger.debug("discard-transient cache=\(self.logID, privacy: .public) key=\(entry.record.key, privacy: .public) reason=last-lease-released")
            scheduleCleanup(entry)
            await cleanupTasks[generation]?.value
        }
    }

    // MARK: Full response production

    private func produce(_ generation: UUID) async {
        guard let entry = entries[generation] else { return }
        do {
            guard let request = try await prepare(entry) else { return }
            logger.debug("http-start cache=\(self.logID, privacy: .public) key=\(entry.record.key, privacy: .public) generation=\(generation, privacy: .public) conditional=\(entry.conditional) hasETag=\(request.value(forHTTPHeaderField: "If-None-Match") != nil) hasLastModified=\(request.value(forHTTPHeaderField: "If-Modified-Since") != nil)")
            try await transport.execute(request: request, onResponse: { response, sentAt, receivedAt in
                try await self.receiveResponse(generation, response: response, sentAt: sentAt, receivedAt: receivedAt)
            }, onData: { data in
                try await self.receiveData(generation, data: data)
            })
            try await finish(entry)
        } catch {
            logger.debug("producer-failed cache=\(self.logID, privacy: .public) key=\(entry.record.key, privacy: .public) cancelled=\(error is CancellationError) cacheError=\(String(describing: error as? MediaCacheError), privacy: .public) domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            await failProduction(entry, error: error)
        }
    }

    private func prepare(_ entry: Entry) async throws -> URLRequest? {
        await lockDisk()
        defer { unlockDisk() }
        try requireValid(entry)
        guard !entry.waiters.isEmpty else { entry.work = nil; return nil }
        if entry.ready {
            let valid = try await disk.validate(record: entry.record)
            try requireValid(entry)
            if valid, entry.record.freshUntil > clock() {
                logger.debug("disk-hit cache=\(self.logID, privacy: .public) key=\(entry.record.key, privacy: .public) generation=\(entry.record.generation, privacy: .public) freshForSeconds=\(entry.record.freshUntil.timeIntervalSince(self.clock()))")
                entry.record.lastAccess = clock()
                try await flushTags(entry, force: true)
                try deliver(entry)
                entry.work = nil
                return nil
            }
            logger.debug("disk-reload cache=\(self.logID, privacy: .public) key=\(entry.record.key, privacy: .public) reason=\(valid ? "stale" : "missing-or-corrupt", privacy: .public) freshForSeconds=\(entry.record.freshUntil.timeIntervalSince(self.clock()))")
            guard let request = entry.request else { throw MediaCacheError.invalidRequest }
            let replacement = makeEntry(key: entry.record.key, tags: entry.tags, request: request)
            replacement.previous = valid ? entry.record.generation : nil
            moveWaiters(from: entry, to: replacement)
            entry.work = nil
            entry.request = nil
            if !valid {
                invalidate(entry, error: MediaCacheError.invalidated)
                entries.removeValue(forKey: entry.record.generation)
            }
            start(replacement)
            return nil
        }
        try await ensureStored(entry)
        try await flushTags(entry)
        try requireValid(entry)
        guard var request = entry.request else { throw MediaCacheError.invalidRequest }
        if let previous = entry.previous.flatMap({ entries[$0] }), previous.valid {
            if let etag = previous.record.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
                entry.conditional = true
            } else if let lastModified = previous.record.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
                entry.conditional = true
            }
        }
        return request
    }

    private func receiveResponse(_ generation: UUID, response: HTTPURLResponse,
                                 sentAt: Date, receivedAt: Date) async throws {
        let representation = try HTTPRepresentation(response: response, sentAt: sentAt, receivedAt: receivedAt)
        guard let entry = entries[generation] else { throw MediaCacheError.invalidated }
        try requireValid(entry)
        guard entry.response == nil else { throw MediaCacheError.invalidResponse }
        entry.response = representation
        logger.debug("http-response cache=\(self.logID, privacy: .public) key=\(entry.record.key, privacy: .public) generation=\(generation, privacy: .public) status=\(representation.statusCode) retained=\(representation.retained) freshForSeconds=\(representation.freshUntil.timeIntervalSince(receivedAt)) hasETag=\(representation.etag != nil) hasLastModified=\(representation.lastModified != nil)")
        if !representation.retained, joinable[entry.record.key] == generation {
            joinable.removeValue(forKey: entry.record.key)
        }
        await lockDisk()
        defer { unlockDisk() }
        try requireValid(entry)
        if representation.statusCode == 304 {
            guard entry.conditional, let previousID = entry.previous,
                  let previous = entries[previousID], previous.valid, previous.ready,
                  representation.contentLength == nil || representation.contentLength == previous.record.contentLength else {
                throw MediaCacheError.invalidResponse
            }
            guard try await disk.validate(record: previous.record) else { throw MediaCacheError.invalidResponse }
            try requireValid(entry)
            try requireValid(previous)
            entry.notModified = true
            if !representation.retained {
                previous.record.retained = false
                do {
                    try await flushTags(previous, force: true)
                } catch {
                    // A failed transient-marker write must not restore retained lookup.
                    invalidate(previous, error: error)
                    do {
                        try await disk.remove(record: previous.record)
                        entries.removeValue(forKey: previousID)
                    } catch {
                        storageError = error
                        throw error
                    }
                    throw error
                }
                try requireValid(entry)
            }
        } else {
            if let previousID = entry.previous, let previous = entries[previousID], previous.valid {
                // Replacement never overwrites a leased generation. Revocation precedes
                // the asynchronous unlink and all later decoder results must check it.
                invalidate(previous, error: MediaCacheError.invalidated)
                do {
                    try await disk.remove(record: previous.record)
                } catch {
                    storageError = error
                    throw error
                }
                entries.removeValue(forKey: previousID)
                try requireValid(entry)
            }
            entry.previous = nil
            entry.record.contentLength = representation.contentLength
            entry.record.mimeType = representation.mimeType
            entry.record.etag = representation.etag
            entry.record.lastModified = representation.lastModified
            entry.record.freshUntil = representation.freshUntil
            entry.record.retained = representation.retained
        }
        try await flushTags(entry, force: true)
    }

    private func receiveData(_ generation: UUID, data: Data) async throws {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw MediaCacheError.invalidResponse }
        await lockDisk()
        defer { unlockDisk() }
        guard let entry = entries[generation] else { throw MediaCacheError.invalidated }
        try requireValid(entry)
        guard entry.response != nil, !entry.notModified else { throw MediaCacheError.invalidResponse }
        let (end, overflow) = entry.record.committedBytes.addingReportingOverflow(Int64(data.count))
        guard !overflow, entry.record.contentLength.map({ end <= $0 }) ?? true else {
            throw MediaCacheError.invalidResponse
        }
        entry.record.tags = entry.tags
        let reservation = try Self.reservation(for: entry.record, payloadBytes: Int64(data.count))
        try await reserve(reservation, protecting: generation)
        defer { reservedBytes = 0 }
        try requireValid(entry)
        entry.record = try await disk.write(record: entry.record, offset: entry.record.committedBytes, data: data)
        entry.durableRecord = entry.record
        try requireValid(entry)
        try await enforceCapacity()
    }

    private func finish(_ entry: Entry) async throws {
        await lockDisk()
        defer { unlockDisk() }
        try requireValid(entry)
        guard let response = entry.response else { throw MediaCacheError.invalidResponse }
        if entry.notModified {
            guard let previousID = entry.previous, let previous = entries[previousID], previous.valid else {
                throw MediaCacheError.invalidated
            }
            previous.tags.formUnion(entry.tags)
            previous.record.etag = response.etag ?? previous.record.etag
            previous.record.lastModified = response.lastModified ?? previous.record.lastModified
            previous.record.mimeType = response.mimeType ?? previous.record.mimeType
            previous.record.freshUntil = response.freshUntil
            previous.record.lastAccess = clock()
            previous.record.retained = response.retained
            try await flushTags(previous, force: true)
            try requireValid(entry)
            try await disk.remove(record: entry.record)
            try requireValid(entry)
            // A retained 304 remains joinable while the marker is deleted. Include
            // tags from every join that arrived during any of the preceding IO.
            repeat {
                previous.tags.formUnion(entry.tags)
                try await flushTags(previous)
                try requireValid(entry)
            } while !entry.tags.isSubset(of: previous.record.tags)
            moveWaiters(from: entry, to: previous)
            entry.work = nil
            cachedContents.remove(key: entry.record.key, generation: entry.record.generation)
            entry.valid = false
            entries.removeValue(forKey: entry.record.generation)
            if response.retained {
                joinable[previous.record.key] = previousID
            } else if joinable[previous.record.key] == entry.record.generation {
                joinable.removeValue(forKey: previous.record.key)
            }
            logger.debug("revalidated cache=\(self.logID, privacy: .public) key=\(previous.record.key, privacy: .public) generation=\(previousID, privacy: .public) status=304")
            try deliver(previous)
            return
        }
        guard entry.record.contentLength == nil || entry.record.contentLength == entry.record.committedBytes else {
            throw MediaCacheError.invalidResponse
        }
        entry.record.contentLength = entry.record.committedBytes
        entry.record.lastAccess = clock()
        try await flushTags(entry, force: true)
        try requireValid(entry)
        entry.ready = true
        entry.work = nil
        logger.debug("stored cache=\(self.logID, privacy: .public) key=\(entry.record.key, privacy: .public) generation=\(entry.record.generation, privacy: .public) bytes=\(entry.record.committedBytes) retained=\(entry.record.retained)")
        try deliver(entry)
    }

    private func failProduction(_ entry: Entry, error: any Error) async {
        guard entry.valid else { return }
        if entry.ready {
            for id in Array(entry.waiters) { failWaiter(id, error: error) }
            entry.work = nil
            entry.request = nil
            return
        }
        invalidate(entry, error: error)
        beginBarrier(entry.record.key)
        await lockDisk()
        do {
            try await disk.remove(record: entry.record)
            entries.removeValue(forKey: entry.record.generation)
            try await discardUnusedTransientPrevious(entry)
        } catch { storageError = error }
        entry.work = nil
        restorePrevious(entry)
        endBarrier(entry.record.key)
        unlockDisk()
    }

    private func moveWaiters(from source: Entry, to destination: Entry) {
        for id in source.waiters {
            waiters[id]?.generation = destination.record.generation
            destination.waiters.insert(id)
        }
        source.waiters.removeAll()
    }

    // MARK: Serialized durable mutations and quota

    private func ensureStored(_ entry: Entry) async throws {
        try requireValid(entry)
        guard !entry.stored else { return }
        entry.record.tags = entry.tags
        try await reserve(try Self.reservation(for: entry.record, payloadBytes: 0), protecting: entry.record.generation)
        defer { reservedBytes = 0 }
        try requireValid(entry)
        _ = try await disk.create(record: entry.record)
        entry.stored = true
        entry.durableRecord = entry.record
        try requireValid(entry)
        try await enforceCapacity()
    }

    private func flushTags(_ entry: Entry, force: Bool = false) async throws {
        var needsWrite = force
        while needsWrite || entry.record.tags != entry.tags {
            try requireValid(entry)
            entry.record.tags = entry.tags
            do {
                try await reserve(try Self.reservation(for: entry.record, payloadBytes: 0), protecting: entry.record.generation)
                try requireValid(entry)
                try await disk.persist(record: entry.record)
                entry.durableRecord = entry.record
                try requireValid(entry)
                try await enforceCapacity()
                reservedBytes = 0
            } catch {
                reservedBytes = 0
                if let durable = entry.durableRecord { entry.record = durable }
                throw error
            }
            needsWrite = false
        }
    }

    private static func reservation(for record: EntryRecord, payloadBytes: Int64) throws -> Int64 {
        // Reserve allocation-rounded incoming bytes and an atomic metadata replacement.
        // Six bytes per UTF-8 byte bounds JSON escaping; the fixed portion covers the
        // record, marker, and directory allocation when this is a new generation.
        var metadata: Int64 = 4_096
        func account(_ value: String?) throws {
            guard let value else { return }
            let (escaped, overflow) = Int64(value.utf8.count).multipliedReportingOverflow(by: 6)
            let (sum, additionOverflow) = metadata.addingReportingOverflow(escaped)
            guard !overflow, !additionOverflow else { throw MediaCacheError.quotaExceeded }
            metadata = sum
        }
        for tag in record.tags { try account(tag.rawValue) }
        try account(record.mimeType)
        try account(record.etag)
        try account(record.lastModified)
        let (total, overflow) = metadata.addingReportingOverflow(payloadBytes)
        guard !overflow, total <= Int64.max - 12_287 else { throw MediaCacheError.quotaExceeded }
        return ((total + 4_095) / 4_096) * 4_096 + 8_192
    }

    private func reserve(_ bytes: Int64, protecting generation: UUID) async throws {
        guard reservedBytes == 0 else { throw MediaCacheError.storageFailure }
        guard bytes <= configuration.maximumDiskBytes else { throw MediaCacheError.quotaExceeded }
        let target = configuration.maximumDiskBytes - bytes
        let removal = try await trimLocked(to: target, protecting: generation)
        guard removal.remainingAllocatedDiskBytes <= target else { throw MediaCacheError.quotaExceeded }
        reservedBytes = bytes
    }

    private func enforceCapacity() async throws {
        let allocation = try await disk.allocations()
        guard try Self.totalAllocation(allocation) <= configuration.maximumDiskBytes else {
            throw MediaCacheError.quotaExceeded
        }
    }

    private func initializeCapacity() async throws {
        await lockDisk()
        defer { unlockDisk() }
        _ = try await trimLocked(to: configuration.maximumDiskBytes)
    }

    private func trimLocked(to limit: Int64, protecting generation: UUID? = nil) async throws -> CacheRemoval {
        var allocation = try await disk.allocations()
        var remaining = try Self.totalAllocation(allocation)
        var count = 0
        var cached: Int64 = 0
        let startingAllocation = remaining
        let revalidating = Set(entries.values.filter { $0.valid }.compactMap(\.previous))
        let candidates = entries.values.filter {
            $0.valid && $0.ready && $0.leases.isEmpty && $0.waiters.isEmpty && $0.work == nil
                && $0.record.generation != generation && !revalidating.contains($0.record.generation)
        }.sorted {
            if $0.record.lastAccess != $1.record.lastAccess { return $0.record.lastAccess < $1.record.lastAccess }
            if $0.record.key != $1.record.key { return $0.record.key < $1.record.key }
            return $0.record.generation.uuidString < $1.record.generation.uuidString
        }
        for entry in candidates where remaining > limit {
            // A caller may have acquired the candidate while allocation IO was suspended.
            guard entry.valid, entry.leases.isEmpty, entry.waiters.isEmpty, entry.work == nil,
                  !entries.values.contains(where: { $0.valid && $0.previous == entry.record.generation }) else { continue }
            logger.debug("evict-lru cache=\(self.logID, privacy: .public) key=\(entry.record.key, privacy: .public) bytes=\(entry.record.committedBytes) target=\(limit)")
            invalidate(entry, error: MediaCacheError.invalidated)
            beginBarrier(entry.record.key)
            do {
                try await disk.remove(record: entry.record)
                entries.removeValue(forKey: entry.record.generation)
            } catch {
                storageError = error
                endBarrier(entry.record.key)
                throw error
            }
            count += 1
            cached += entry.record.committedBytes
            endBarrier(entry.record.key)
            allocation = try await disk.allocations()
            remaining = try Self.totalAllocation(allocation)
        }
        return CacheRemoval(removedItemCount: count, removedCachedBytes: cached,
                            removedAllocatedDiskBytes: max(0, startingAllocation - remaining),
                            remainingAllocatedDiskBytes: remaining)
    }

    private static func totalAllocation(_ allocation: (entries: [UUID: Int64], overhead: Int64)) throws -> Int64 {
        var total = allocation.overhead
        for bytes in allocation.entries.values {
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { throw MediaCacheError.storageFailure }
            total = sum
        }
        return total
    }

    // MARK: Invalidation barriers and repair

    private func removeMatching(_ matches: (Set<CacheTag>) -> Bool) async throws -> CacheRemoval {
        try checkOpen()
        let selected = entries.values.filter { $0.valid && matches($0.tags) }
        logger.debug("remove cache=\(self.logID, privacy: .public) selected=\(selected.count)")
        let selectedKeys = Set(selected.map { $0.record.key })
        let producers = selected.compactMap(\.work)
        let pendingCleanup = entries.values.filter { !$0.valid && matches($0.tags) }
            .compactMap { cleanupTasks[$0.record.generation] }
        for key in selectedKeys { beginBarrier(key) }
        for entry in selected { invalidate(entry, error: MediaCacheError.invalidated) }
        for (id, waiter) in Array(waiters) where waiter.generation == nil && matches(waiter.tags) {
            failWaiter(id, error: MediaCacheError.invalidated)
        }
        // Do not hold the mutation gate while draining callbacks: a canceled HTTP
        // handoff must be allowed to enter, observe invalidation, and finish.
        for producer in producers { await producer.value }
        for cleanup in pendingCleanup { await cleanup.value }
        await lockDisk()
        defer {
            for key in selectedKeys { endBarrier(key) }
            unlockDisk()
        }
        try checkOpen()
        let cached = selected.reduce(Int64(0)) { $0 + $1.record.committedBytes }
        let before = try await disk.allocations()
        let startingAllocation = try Self.totalAllocation(before)
        do {
            for entry in selected {
                try await disk.remove(record: entry.record)
                entries.removeValue(forKey: entry.record.generation)
            }
        } catch {
            storageError = error
            throw error
        }
        let remaining = try Self.totalAllocation(try await disk.allocations())
        return CacheRemoval(removedItemCount: selected.count, removedCachedBytes: cached,
                            removedAllocatedDiskBytes: max(0, startingAllocation - remaining),
                            remainingAllocatedDiskBytes: remaining)
    }

    private func invalidate(_ entry: Entry, error: any Error) {
        guard entry.valid else { return }
        cachedContents.remove(key: entry.record.key, generation: entry.record.generation)
        logger.debug("invalidate cache=\(self.logID, privacy: .public) key=\(entry.record.key, privacy: .public) generation=\(entry.record.generation, privacy: .public) cancelled=\(error is CancellationError) cacheError=\(String(describing: error as? MediaCacheError), privacy: .public) domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
        entry.valid = false
        entry.work?.cancel()
        entry.leases.removeAll()
        if joinable[entry.record.key] == entry.record.generation { joinable.removeValue(forKey: entry.record.key) }
        for id in Array(entry.waiters) { failWaiter(id, error: error) }
    }

    private func scheduleCleanup(_ entry: Entry) {
        let generation = entry.record.generation
        guard cleanupTasks[generation] == nil else { return }
        beginBarrier(entry.record.key)
        let producer = entry.work
        cleanupTasks[generation] = Task {
            await producer?.value
            await self.lockDisk()
            if !self.closed {
                do {
                    try await self.disk.remove(record: entry.record)
                    self.entries.removeValue(forKey: generation)
                    try await self.discardUnusedTransientPrevious(entry)
                } catch { self.storageError = error }
                self.restorePrevious(entry)
            }
            self.cleanupTasks.removeValue(forKey: generation)
            self.endBarrier(entry.record.key)
            self.unlockDisk()
        }
    }

    private func restorePrevious(_ entry: Entry) {
        guard joinable[entry.record.key] == nil, let previousID = entry.previous,
              let previous = entries[previousID], previous.valid, previous.record.retained else { return }
        joinable[entry.record.key] = previousID
    }

    private func discardUnusedTransientPrevious(_ entry: Entry) async throws {
        guard let previousID = entry.previous, let previous = entries[previousID], previous.valid,
              !previous.record.retained, previous.leases.isEmpty, previous.waiters.isEmpty,
              !entries.values.contains(where: { $0.valid && $0.previous == previousID }) else { return }
        invalidate(previous, error: MediaCacheError.invalidated)
        try await disk.remove(record: previous.record)
        entries.removeValue(forKey: previousID)
    }

    private func repairEntries() async throws {
        for entry in Array(entries.values) where entry.valid && entry.stored {
            if try await disk.validate(record: entry.record) == false, entry.valid {
                invalidate(entry, error: MediaCacheError.invalidated)
                scheduleCleanup(entry)
            }
        }
    }

    private static func accumulate(_ entry: Entry, allocated: Int64, into bucket: inout CacheUsageBucket) {
        bucket.itemCount += 1
        if entry.ready && entry.record.complete { bucket.completeItemCount += 1 }
        bucket.cachedBytes += entry.record.committedBytes
        bucket.allocatedDiskBytes += allocated
        if !entry.record.retained { bucket.transientDiskBytes += allocated }
    }

    private func beginBarrier(_ key: String) { barriers[key, default: 0] += 1 }

    private func endBarrier(_ key: String) {
        guard let count = barriers[key] else { return }
        if count > 1 { barriers[key] = count - 1; return }
        barriers.removeValue(forKey: key)
        for id in Array(waiters.keys) where waiters[id]?.key == key && waiters[id]?.generation == nil { admit(id) }
    }

    private func checkOpen() throws {
        guard !closed else { throw MediaCacheError.closed }
        if let storageError { throw storageError }
    }

    private func requireValid(_ entry: Entry) throws {
        try checkOpen()
        guard entry.valid else { throw MediaCacheError.invalidated }
    }

    private func lockDisk() async {
        if diskLocked {
            await withCheckedContinuation { diskWaiters.append($0) }
        } else {
            diskLocked = true
        }
    }

    private func unlockDisk() {
        if diskWaiters.isEmpty { diskLocked = false }
        else { diskWaiters.removeFirst().resume() }
    }
}
