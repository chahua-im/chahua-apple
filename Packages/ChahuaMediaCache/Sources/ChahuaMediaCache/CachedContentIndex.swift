import Foundation

/// Metadata only: every value and the admission fence are confined to this lock.
/// Identifiers authorize decoded-memory lookup, never access to the payload file.
final class CachedContentIndex: @unchecked Sendable {
    struct Content: Sendable {
        let generation: UUID
        let identifier: String
        let tags: Set<CacheTag>
        let freshUntil: Date
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var contents: [String: Content] = [:]
    private var closed = false

    init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    func identifier(for key: String, tags: Set<CacheTag>) -> String? {
        lock.withLock {
            guard !closed, let content = contents[key],
                  content.freshUntil > clock(), tags.isSubset(of: content.tags) else { return nil }
            return content.identifier
        }
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
