import ChahuaAPI
import Combine
import Foundation

/// Saved state belongs to an account, not to the live message cache. Source recalls,
/// edits and membership changes must never rewrite or discard captured content.
@MainActor
final class SavedMessageController: ObservableObject {
    @Published private(set) var items: [SavedMessageResponse] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoadingList = false
    @Published private(set) var hasLoadedList = false
    @Published private(set) var listError: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var revision = 0
    @Published private var scopes: [String: Set<MessageID>] = [:]
    @Published private var loadingScopes = Set<String>()
    @Published private var scopeErrors: [String: String] = [:]
    @Published private var mutations = Set<Key>()
    let removedSnapshots = PassthroughSubject<String, Never>()

    private struct Key: Hashable {
        let chatID: String
        let messageID: MessageID
    }
    private let apiClient: any ChahuaAPIClient
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var accountID: Int32?
    private var generation = 0
    private var scopeTasks: [String: Task<Void, Never>] = [:]
    private var scopeOverrides: [Key: (version: Int, saved: Bool)] = [:]
    private var removedIDs = Set<String>()
    private var mutationVersion = 0
    private var additions: [String: (version: Int, item: SavedMessageResponse)] = [:]
    private var failedListWasMore = false

    init(
        apiClient: any ChahuaAPIClient,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.apiClient = apiClient
        self.onInvalidToken = onInvalidToken
    }

    func setAccount(_ uid: Int32?) {
        guard uid != accountID else { return }
        reset()
        accountID = uid
    }

    func reset() {
        generation &+= 1
        for task in scopeTasks.values { task.cancel() }
        scopeTasks.removeAll()
        accountID = nil
        scopes.removeAll()
        scopeOverrides.removeAll()
        loadingScopes.removeAll()
        scopeErrors.removeAll()
        mutations.removeAll()
        items.removeAll()
        removedIDs.removeAll()
        additions.removeAll()
        nextCursor = nil
        isLoadingList = false
        hasLoadedList = false
        listError = nil
        errorMessage = nil
        revision &+= 1
    }

    func isSaved(chatID: String, messageID: MessageID) -> Bool {
        scopes[chatID]?.contains(messageID) == true
    }

    func hasLoaded(chatID: String) -> Bool { scopes[chatID] != nil }
    func isLoading(chatID: String) -> Bool { loadingScopes.contains(chatID) }
    func scopeError(chatID: String) -> String? { scopeErrors[chatID] }
    func isMutating(chatID: String, messageID: MessageID) -> Bool {
        mutations.contains(Key(chatID: chatID, messageID: messageID))
    }
    func clearError() { errorMessage = nil }

    func savedIDs(chatID: String) -> Set<MessageID> { scopes[chatID] ?? [] }
    func pendingIDs(chatID: String) -> Set<MessageID> {
        Set(mutations.lazy.filter { $0.chatID == chatID }.map(\.messageID))
    }

    func ensure(chatID: String) async {
        guard accountID != nil, !hasLoaded(chatID: chatID) else { return }
        if let task = scopeTasks[chatID] {
            await task.value
            return
        }
        let requestGeneration = generation
        let startVersion = mutationVersion
        loadingScopes.insert(chatID)
        scopeErrors[chatID] = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration {
                    loadingScopes.remove(chatID)
                    scopeTasks[chatID] = nil
                }
            }
            do {
                var ids = Set<MessageID>()
                var before: String?
                repeat {
                    let page = try await apiClient.listChatSavedMessages(
                        chatID: chatID, before: before, limit: 50)
                    try checkSession(requestGeneration)
                    ids.formUnion(page.savedMessages.map(\.originalMessageId))
                    let next = page.nextCursor
                    guard next != before else { break }
                    before = next
                } while before != nil
                for (key, change) in scopeOverrides
                where key.chatID == chatID && change.version > startVersion {
                    if change.saved { ids.insert(key.messageID) } else { ids.remove(key.messageID) }
                }
                scopes[chatID] = ids
            } catch {
                guard generation == requestGeneration, !(error is CancellationError) else { return }
                // This is background menu metadata, not a user-initiated mutation.
                // Keep failure visible/retryable in its chat without presenting a modal.
                scopeErrors[chatID] = String(localized: "Couldn’t load saved-message status.")
                if case APIError.invalidToken = error { await onInvalidToken() }
            }
        }
        scopeTasks[chatID] = task
        await task.value
    }

    func toggle(_ message: MessageResponse) async {
        let initialGeneration = generation
        await ensure(chatID: message.chatId)
        guard generation == initialGeneration, hasLoaded(chatID: message.chatId) else { return }
        let key = Key(chatID: message.chatId, messageID: message.id)
        guard !mutations.contains(key), accountID != nil else { return }
        let requestGeneration = generation
        let removing = isSaved(chatID: key.chatID, messageID: key.messageID)
        mutations.insert(key)
        errorMessage = nil
        defer { if generation == requestGeneration { mutations.remove(key) } }
        do {
            if removing {
                try await apiClient.removeSavedMessage(originalMessageID: message.id)
                try checkSession(requestGeneration)
                let matches = items.filter {
                    $0.originalChatId == key.chatID && $0.originalMessageId == key.messageID
                }
                for item in matches {
                    removedIDs.insert(item.id)
                    additions[item.id] = nil
                    removedSnapshots.send(item.id)
                }
                items.removeAll {
                    $0.originalChatId == key.chatID && $0.originalMessageId == key.messageID
                }
                write(key, saved: false)
            } else {
                let captured = try await apiClient.saveMessage(messageID: message.id)
                try checkSession(requestGeneration)
                mutationVersion &+= 1
                additions[captured.id] = (mutationVersion, captured)
                removedIDs.remove(captured.id)
                items.removeAll { $0.id == captured.id }
                items.insert(captured, at: 0)
                write(key, saved: true)
            }
        } catch {
            await report(error, generation: requestGeneration)
        }
    }

    func remove(_ item: SavedMessageResponse) async -> Bool {
        let key = Key(chatID: item.originalChatId, messageID: item.originalMessageId)
        guard accountID != nil, !mutations.contains(key) else { return false }
        let requestGeneration = generation
        mutations.insert(key)
        errorMessage = nil
        defer { if generation == requestGeneration { mutations.remove(key) } }
        do {
            // This deletes only the saved resource, never the source message.
            try await apiClient.removeSavedMessage(savedMessageID: item.id)
            try checkSession(requestGeneration)
            removedIDs.insert(item.id)
            additions[item.id] = nil
            removedSnapshots.send(item.id)
            items.removeAll { $0.id == item.id }
            write(key, saved: false)
            return true
        } catch {
            await report(error, generation: requestGeneration)
            return false
        }
    }

    func loadList(more: Bool = false) async {
        guard accountID != nil, !isLoadingList, !more || nextCursor != nil else { return }
        let requestGeneration = generation
        let before = more ? nextCursor : nil
        let startVersion = mutationVersion
        isLoadingList = true
        listError = nil
        defer { if generation == requestGeneration { isLoadingList = false } }
        do {
            let page = try await apiClient.listSavedMessages(before: before, limit: 50)
            try checkSession(requestGeneration)
            var merged = more ? items : []
            var seen = Set(merged.map(\.id))
            for item in page.savedMessages where !removedIDs.contains(item.id) {
                let key = Key(chatID: item.originalChatId, messageID: item.originalMessageId)
                if let change = scopeOverrides[key], !change.saved, change.version > startVersion {
                    continue
                }
                if seen.insert(item.id).inserted { merged.append(item) }
            }
            if !more {
                let concurrent = additions.values.filter { $0.version > startVersion }
                    .sorted { $0.version > $1.version }.map(\.item)
                let ids = Set(concurrent.map(\.id))
                merged.removeAll { ids.contains($0.id) }
                merged.insert(contentsOf: concurrent, at: 0)
            }
            items = merged
            nextCursor = page.nextCursor == before ? nil : page.nextCursor
            hasLoadedList = true
            additions = additions.filter { $0.value.version > startVersion }
        } catch {
            guard generation == requestGeneration, !(error is CancellationError) else { return }
            listError = String(localized: "Couldn’t load saved messages. Try again.")
            failedListWasMore = more
            if case APIError.invalidToken = error { await onInvalidToken() }
        }
    }

    func retryList() async { await loadList(more: failedListWasMore) }

    private func write(_ key: Key, saved: Bool) {
        mutationVersion &+= 1
        scopeOverrides[key] = (mutationVersion, saved)
        if scopes[key.chatID] != nil {
            if saved {
                scopes[key.chatID]?.insert(key.messageID)
            } else {
                scopes[key.chatID]?.remove(key.messageID)
            }
        }
    }

    private func checkSession(_ requestGeneration: Int) throws {
        try Task.checkCancellation()
        guard generation == requestGeneration, accountID != nil else { throw CancellationError() }
    }

    private func report(_ error: any Error, generation requestGeneration: Int) async {
        guard generation == requestGeneration, !(error is CancellationError) else { return }
        errorMessage = String(localized: "Couldn’t update saved messages. Try again.")
        if case APIError.invalidToken = error { await onInvalidToken() }
    }
}
