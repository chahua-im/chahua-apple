import Foundation

/// Metadata only: every value and the admission fence are confined to this lock.
/// Identifiers authorize decoded-memory lookup, never access to the payload file.
final class CachedContentIndex: @unchecked Sendable {
    struct Content: Sendable {
        let generation: UUID
        let identifier: String
        let tags: Set<CacheTag>
        let freshUntil: Date
        let allowsStale: Bool
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var contents: [String: Content] = [:]
    private var closed = false

    init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    func identifier(for key: String, tags: Set<CacheTag>, allowingStale: Bool) -> String? {
        guard AvatarCacheTrace.enabled, AvatarCacheTrace.load != nil,
              tags.contains(CacheTag(rawValue: "avatars")) else {
            return lock.withLock {
                guard !closed, let content = contents[key],
                      (content.freshUntil > clock() || (allowingStale && content.allowsStale)),
                      tags.isSubset(of: content.tags) else { return nil }
                return content.identifier
            }
        }
        let result: (identifier: String?, reason: String, generation: UUID?, ttl: TimeInterval?) = lock.withLock {
            guard !closed else { return (nil, "closed", nil, nil) }
            guard let content = contents[key] else { return (nil, "no-entry", nil, nil) }
            let now = clock()
            let ttl = content.freshUntil.timeIntervalSince(now)
            guard content.freshUntil > now || (allowingStale && content.allowsStale) else {
                return (nil, "expired", content.generation, ttl)
            }
            guard tags.isSubset(of: content.tags) else {
                return (nil, "tags-not-registered", content.generation, ttl)
            }
            return (content.identifier, "hit", content.generation, ttl)
        }
        // Use the decision's clock sample and emit only after releasing the index lock.
        let fingerprint = AvatarCacheTrace.key(forNormalizedKey: key)
        let generation = result.generation.map { String($0.uuidString.prefix(8)) } ?? "-"
        let ttl = result.ttl.map { String(format: "%.3f", $0) } ?? "-"
        AvatarCacheTrace.event("event=metadata_lookup key=\(fingerprint) gen=\(generation) reason=\(result.reason) ttl_s=\(ttl)")
        return result.identifier
    }

    func publish(_ content: Content, for key: String) {
        lock.withLock {
            guard !closed else { return }
            contents[key] = content
        }
    }

    func remove(key: String, generation: UUID) {
        lock.withLock {
            guard contents[key]?.generation == generation else { return }
            contents.removeValue(forKey: key)
        }
    }

    func close() {
        lock.withLock {
            closed = true
            contents.removeAll()
        }
    }
}
