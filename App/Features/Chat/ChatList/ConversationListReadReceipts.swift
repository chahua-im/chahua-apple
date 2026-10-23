import ChahuaAPI
import Combine
import Foundation

/// The list uses the same authorized high-water marks as the timeline, including
/// when no conversation is open. Versions fence both list snapshots and HTTP
/// receipts across policy changes; a failed reauthorization leaves a single check.
@MainActor
final class ConversationListReadReceipts: ObservableObject {
    @Published private(set) var values: [ConversationKey: MessageID] = [:]
    private var knownScopes = Set<ConversationKey>()
    private var revision = 0
    private var versions: [ConversationKey: Int] = [:]
    private var privacyVersions: [String: Int] = [:]
    private var privacyVersion = 0
    private var tasks: [ConversationKey: Task<Void, Never>] = [:]
    private var dirty = Set<ConversationKey>()
    private var generation = 0

    func snapshot() -> Int {
        revision += 1
        return revision
    }

    @discardableResult
    func accept(_ value: MessageID?, for key: ConversationKey, version: Int) -> Bool {
        knownScopes.insert(key)
        guard version >= versions[key, default: 0], version >= privacyVersion,
            version >= privacyVersions[key.chatID, default: 0]
        else { return false }
        versions[key] = version
        if values[key] != value { values[key] = value }
        return true
    }

    func acceptIfKnown(_ value: MessageID?, for key: ConversationKey, version: Int) {
        guard knownScopes.contains(key) else { return }
        accept(value, for: key, version: version)
    }

    func refresh(
        chatID: String? = nil, threadID: String? = nil, clear: Bool = false,
        fetch: @escaping @MainActor (ConversationKey) async throws -> MessageID?
    ) {
        // A chat-wide policy event must also fence a snapshot for a previously
        // unseen topic, not just the currently loaded parent or reply scopes.
        let version = snapshot()
        if clear, let chatID { privacyVersions[chatID] = version }
        if clear, chatID == nil { privacyVersion = version }
        for key in knownScopes
        where (chatID == nil || key.chatID == chatID)
            && (clear || key.threadID == threadID)
        {
            versions[key] = version
            if clear { values[key] = nil }
            dirty.insert(key)
            guard tasks[key] == nil else { continue }
            let requestGeneration = generation
            tasks[key] = Task { [weak self] in
                guard let self, self.generation == requestGeneration, !Task.isCancelled else {
                    return
                }
                defer {
                    if generation == requestGeneration { tasks[key] = nil }
                }
                repeat {
                    dirty.remove(key)
                    let requestVersion = versions[key, default: 0]
                    do {
                        let value = try await fetch(key)
                        guard generation == requestGeneration, !Task.isCancelled else { return }
                        accept(value, for: key, version: requestVersion)
                    } catch {
                        guard generation == requestGeneration, !Task.isCancelled else { return }
                        // Keep the last authorized result unless it was revoked.
                    }
                } while dirty.contains(key) && !Task.isCancelled
            }
        }
    }

    func reset() {
        generation += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        dirty.removeAll()
        values.removeAll()
        knownScopes.removeAll()
        versions.removeAll()
        privacyVersions.removeAll()
        privacyVersion = 0
        revision = 0
    }
}
