import ChahuaAPI
import Combine
import Foundation

/// Chat-only pin snapshots, with in-flight ingress replayed over HTTP responses.
@MainActor
final class ChatPinController: ObservableObject {
    @Published private(set) var pinsByChatID: [String: [PinResponse]] = [:]
    @Published private(set) var loadingChatIDs = Set<String>()
    @Published private(set) var failedChatIDs = Set<String>()
    @Published private(set) var pendingMessageIDs = Set<String>()
    @Published var error: String?

    private let apiClient: any ChahuaAPIClient
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var generation = 0
    private var knownChatIDs = Set<String>()
    private var loadedChatIDs = Set<String>()
    private var loadTasks: [String: Task<Void, Never>] = [:]
    private var loadIDs: [String: UUID] = [:]
    private var refreshDirty = Set<String>()
    private var snapshots: [UUID: Snapshot] = [:]
    // IDs are immutable: late add echoes must not resurrect removed pins/messages.
    private var removedPinIDs: [String: Set<String>] = [:]
    private var deletedMessageIDs: [String: Set<String>] = [:]
    private var expiryTask: Task<Void, Never>?

    private enum Change {
        case add(PinResponse)
        case remove(String)
        case update(MessageResponse)
        case delete(Set<String>)
    }

    private struct Snapshot {
        let chatID: String
        var changes: [Change] = []
    }

    init(
        apiClient: any ChahuaAPIClient,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.apiClient = apiClient
        self.onInvalidToken = onInvalidToken
    }

    deinit { expiryTask?.cancel() }

    func load(chatID: String, force: Bool = false) async {
        guard !chatID.isEmpty, !Task.isCancelled else { return }
        knownChatIDs.insert(chatID)
        pruneExpired()
        if let task = loadTasks[chatID] {
            if force { refreshDirty.insert(chatID) }
            await task.value
            return
        }
        guard force || !loadedChatIDs.contains(chatID) || failedChatIDs.contains(chatID) else { return }
        let requestGeneration = generation
        let requestID = UUID()
        loadIDs[chatID] = requestID
        loadingChatIDs.insert(chatID)
        failedChatIDs.remove(chatID)
        error = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.loadIDs[chatID] == requestID {
                    self.loadIDs.removeValue(forKey: chatID)
                    self.loadTasks.removeValue(forKey: chatID)
                    self.loadingChatIDs.remove(chatID)
                }
            }
            repeat {
                self.refreshDirty.remove(chatID)
                await self.loadSnapshot(chatID: chatID, generation: requestGeneration, requestID: requestID)
            } while self.generation == requestGeneration && self.loadIDs[chatID] == requestID
                && self.refreshDirty.contains(chatID) && !Task.isCancelled
        }
        loadTasks[chatID] = task
        await task.value
    }

    func pin(_ message: MessageResponse) async {
        guard !message.chatId.isEmpty, !message.id.isEmpty, message.replyRootId == nil, !message.isDeleted,
              !pendingMessageIDs.contains(message.id), !Task.isCancelled else { return }
        pruneExpired()
        guard !deletedMessageIDs[message.chatId, default: []].contains(message.id),
              !(pinsByChatID[message.chatId] ?? []).contains(where: { $0.message.id == message.id }) else { return }
        knownChatIDs.insert(message.chatId)
        let requestGeneration = generation
        let token = beginSnapshot(chatID: message.chatId)
        pendingMessageIDs.insert(message.id)
        error = nil
        defer {
            snapshots.removeValue(forKey: token)
            if generation == requestGeneration { pendingMessageIDs.remove(message.id) }
        }
        do {
            let response = try await apiClient.createPin(chatID: message.chatId, messageID: message.id)
            try checkSession(requestGeneration)
            guard validScope(response, chatID: message.chatId), response.message.id == message.id else {
                throw APIError.unexpectedResponse
            }
            var candidate = [response]
            for change in snapshots[token]?.changes ?? [] { reduce(change, into: &candidate) }
            if let pin = normalized(candidate, chatID: message.chatId).first(where: { $0.id == response.id }) {
                apply(.add(pin), chatID: message.chatId)
            }
        } catch {
            await report(error, generation: requestGeneration, message: String(localized: "Couldn’t pin message. Please try again."))
        }
    }

    func unpin(_ pin: PinResponse) async {
        guard validScope(pin, chatID: pin.chatId), !pendingMessageIDs.contains(pin.message.id),
              !Task.isCancelled else { return }
        let requestGeneration = generation
        knownChatIDs.insert(pin.chatId)
        pendingMessageIDs.insert(pin.message.id)
        error = nil
        defer {
            if generation == requestGeneration { pendingMessageIDs.remove(pin.message.id) }
        }
        do {
            try await apiClient.deletePin(chatID: pin.chatId, pinID: pin.id)
            try checkSession(requestGeneration)
            apply(.remove(pin.id), chatID: pin.chatId)
        } catch {
            // Another member (or our websocket echo) can remove it before DELETE returns.
            if generation == requestGeneration, !Task.isCancelled,
               case APIError.http(status: 404, body: _) = error {
                apply(.remove(pin.id), chatID: pin.chatId)
                return
            }
            await report(error, generation: requestGeneration, message: String(localized: "Couldn’t unpin message. Please try again."))
        }
    }

    func applyRealtimeEvent(_ event: RealtimeServerEvent) {
        switch event {
        case .pinAdded(let payload):
            guard payload.threadRootId == nil, let pin = payload.pin,
                  validScope(pin, chatID: payload.chatId), pin.id == payload.pinId,
                  pin.message.id == payload.messageId else { return }
            knownChatIDs.insert(payload.chatId)
            apply(.add(pin), chatID: payload.chatId)
        case .pinRemoved(let payload):
            guard payload.threadRootId == nil, !payload.chatId.isEmpty, !payload.pinId.isEmpty,
                  !payload.messageId.isEmpty else { return }
            if let existing = pinsByChatID[payload.chatId]?.first(where: { $0.id == payload.pinId }),
               existing.message.id != payload.messageId { return }
            knownChatIDs.insert(payload.chatId)
            apply(.remove(payload.pinId), chatID: payload.chatId)
        case .messageUpdated(let message):
            apply(message.isDeleted ? .delete([message.id]) : .update(message), chatID: message.chatId)
        case .messageDeleted(let message):
            apply(.delete([message.id]), chatID: message.chatId)
        case .messagesBulkDeleted(let payload):
            apply(.delete(Set(payload.messageIds)), chatID: payload.chatId)
        default:
            break
        }
    }

    func reconcileAfterReconnect(activeChatIDs: Set<String>) async {
        let chatIDs = knownChatIDs.union(activeChatIDs)
        pruneExpired()
        await withTaskGroup(of: Void.self) { group in
            for chatID in chatIDs { group.addTask { await self.load(chatID: chatID, force: true) } }
        }
    }

    func cancelLoads() {
        for task in loadTasks.values { task.cancel() }
        loadTasks.removeAll()
        loadIDs.removeAll()
        loadingChatIDs.removeAll()
        refreshDirty.removeAll()
    }

    func reset() {
        generation += 1
        cancelLoads()
        expiryTask?.cancel()
        expiryTask = nil
        snapshots.removeAll()
        knownChatIDs.removeAll()
        loadedChatIDs.removeAll()
        removedPinIDs.removeAll()
        deletedMessageIDs.removeAll()
        pinsByChatID.removeAll()
        failedChatIDs.removeAll()
        pendingMessageIDs.removeAll()
        error = nil
    }

    private func loadSnapshot(chatID: String, generation requestGeneration: Int, requestID: UUID) async {
        let token = beginSnapshot(chatID: chatID)
        defer { snapshots.removeValue(forKey: token) }
        do {
            try checkSession(requestGeneration)
            let response = try await apiClient.listPins(chatID: chatID)
            try checkSession(requestGeneration)
            guard loadIDs[chatID] == requestID else { return }
            guard response.pins.allSatisfy({ validScope($0, chatID: chatID) }) else {
                throw APIError.unexpectedResponse
            }
            var pins = response.pins
            for change in snapshots[token]?.changes ?? [] { reduce(change, into: &pins) }
            pinsByChatID[chatID] = normalized(pins, chatID: chatID)
            loadedChatIDs.insert(chatID)
            failedChatIDs.remove(chatID)
            scheduleExpiry()
        } catch {
            guard generation == requestGeneration, loadIDs[chatID] == requestID,
                  !(error is CancellationError), !Task.isCancelled else { return }
            failedChatIDs.insert(chatID)
            await report(error, generation: requestGeneration, message: String(localized: "Couldn’t load pinned messages. Please try again."))
        }
    }

    private func beginSnapshot(chatID: String) -> UUID {
        let token = UUID()
        snapshots[token] = Snapshot(chatID: chatID)
        return token
    }

    private func apply(_ change: Change, chatID: String) {
        guard !chatID.isEmpty, knownChatIDs.contains(chatID) else { return }
        for token in Array(snapshots.keys) where snapshots[token]?.chatID == chatID {
            snapshots[token]?.changes.append(change)
        }
        switch change {
        case .remove(let id): removedPinIDs[chatID, default: []].insert(id)
        case .delete(let ids): deletedMessageIDs[chatID, default: []].formUnion(ids)
        default: break
        }
        var pins = pinsByChatID[chatID] ?? []
        reduce(change, into: &pins)
        pinsByChatID[chatID] = normalized(pins, chatID: chatID)
        scheduleExpiry()
    }

    private func reduce(_ change: Change, into pins: inout [PinResponse]) {
        switch change {
        case .add(let pin):
            // Duplicate broadcasts must not replace an already updated message preview.
            guard isLive(pin, chatID: pin.chatId, now: Date()),
                  !pins.contains(where: { $0.id == pin.id }) else { return }
            pins.removeAll { $0.message.id == pin.message.id }
            pins.append(pin)
        case .remove(let id):
            pins.removeAll { $0.id == id }
        case .update(let message):
            for index in pins.indices where pins[index].message.id == message.id {
                let pin = pins[index]
                pins[index] = PinResponse(
                    id: pin.id, chatId: pin.chatId, threadRootId: pin.threadRootId,
                    message: message, pinnedBy: pin.pinnedBy, pinnedAt: pin.pinnedAt, expiresAt: pin.expiresAt)
            }
        case .delete(let ids):
            pins.removeAll { ids.contains($0.message.id) }
        }
    }

    private func validScope(_ pin: PinResponse, chatID: String) -> Bool {
        !chatID.isEmpty && !pin.id.isEmpty && !pin.message.id.isEmpty && pin.chatId == chatID
            && pin.message.chatId == chatID && pin.threadRootId == nil
    }

    private func isLive(_ pin: PinResponse, chatID: String, now: Date) -> Bool {
        validScope(pin, chatID: chatID) && !pin.message.isDeleted
            && (pin.expiresAt.map { $0 > now } ?? true)
            && !removedPinIDs[chatID, default: []].contains(pin.id)
            && !deletedMessageIDs[chatID, default: []].contains(pin.message.id)
    }

    private func normalized(_ pins: [PinResponse], chatID: String) -> [PinResponse] {
        let now = Date()
        var seenPinIDs = Set<String>()
        var seenMessageIDs = Set<String>()
        return pins.filter {
            isLive($0, chatID: chatID, now: now)
        }.sorted {
            if $0.message.createdAt != $1.message.createdAt { return $0.message.createdAt > $1.message.createdAt }
            return $0.id > $1.id
        }.filter { seenPinIDs.insert($0.id).inserted && seenMessageIDs.insert($0.message.id).inserted }
    }

    private func pruneExpired() {
        let now = Date()
        for chatID in Array(pinsByChatID.keys) {
            pinsByChatID[chatID]?.removeAll { $0.expiresAt.map { $0 <= now } ?? false }
        }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let next = pinsByChatID.values.lazy.flatMap({ $0 }).compactMap(\.expiresAt).min() else { return }
        let delay = max(0, next.timeIntervalSinceNow)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.pruneExpired()
        }
    }

    private func checkSession(_ requestGeneration: Int) throws {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
    }

    private func report(_ failure: Error, generation requestGeneration: Int, message: String) async {
        guard generation == requestGeneration, !(failure is CancellationError), !Task.isCancelled else { return }
        error = message
        if case APIError.invalidToken = failure { await onInvalidToken() }
    }
}
