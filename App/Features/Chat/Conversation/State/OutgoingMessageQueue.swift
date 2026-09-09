import ChahuaAPI
import Combine
import Foundation

enum OutgoingStorageState: Equatable {
    case inactive, loading, ready, failed
}

enum OutgoingQueueEvent {
    case snapshot(LocalConversationSnapshot)
    case acknowledged(snapshot: LocalConversationSnapshot?, message: MessageResponse)
}

@MainActor
final class OutgoingMessageQueue: ObservableObject {
    enum StorageOperation: Equatable {
        case restore, saveDraft, enqueue, claim, fail, retry, acknowledge
    }

    enum QueueError: Error {
        case storageUnavailable
        case invalidAcknowledgement
    }

    @Published private(set) var storageState: OutgoingStorageState = .inactive
    @Published private(set) var snapshots: [String: LocalConversationSnapshot] = [:]
    let events = PassthroughSubject<OutgoingQueueEvent, Never>()

    private let apiClient: any ChahuaAPIClient
    private let localStoreFactory: @Sendable (Int32) async throws -> ChahuaLocalStore
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    // A narrow fault-injection boundary; all persistence still uses the concrete store.
    private let beforeStorageOperation: (@MainActor @Sendable (StorageOperation) async throws -> Void)?
    private var store: ChahuaLocalStore?
    private var requestedUID: Int32?
    private var generation: UInt64 = 0
    private var transportGeneration: UInt64 = 0
    private var foregroundActive = false
    private var transportReady = false
    private var lifecycle: Task<Void, Never>?
    private var workers: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var acknowledgements: [String: MessageResponse] = [:]
    private var uncommittedFailures: [String: LocalOutgoingMessage] = [:]
    private var authenticationFailed = false

    init(
        apiClient: any ChahuaAPIClient,
        localStoreFactory: @escaping @Sendable (Int32) async throws -> ChahuaLocalStore,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void,
        beforeStorageOperation: (@MainActor @Sendable (StorageOperation) async throws -> Void)? = nil
    ) {
        self.apiClient = apiClient
        self.localStoreFactory = localStoreFactory
        self.onInvalidToken = onInvalidToken
        self.beforeStorageOperation = beforeStorageOperation
    }

    /// Must run at the synchronous authentication handoff, before opening storage.
    func requestSession(uid: Int32?) {
        guard uid != requestedUID else { return }
        requestedUID = uid
        generation &+= 1
        invalidateTransport()
        let current = generation
        let transport = transportGeneration
        store = nil
        snapshots = [:]
        acknowledgements = [:]
        uncommittedFailures = [:]
        authenticationFailed = false
        storageState = uid == nil ? .inactive : .loading
        let previous = lifecycle
        lifecycle = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.stopWorkers()
            guard self.generation == current, let uid else { return }
            await self.openAndRestore(uid: uid, generation: current, transport: transport)
        }
    }

    func activate(uid: Int32) async {
        requestSession(uid: uid)
        await lifecycle?.value
    }

    func deactivate() async {
        requestSession(uid: nil)
        await lifecycle?.value
    }

    /// Scene aggregation calls this synchronously, independently of socket readiness.
    func requestForegroundActive(_ active: Bool) {
        guard foregroundActive != active else { return }
        foregroundActive = active
        invalidateTransport()
        let current = generation
        let transport = transportGeneration
        let previous = lifecycle
        lifecycle = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.stopWorkers()
            guard self.generation == current, self.transportGeneration == transport,
                  active, self.storageState == .ready, let store = self.store else { return }
            do {
                try await self.checkpoint(.restore, generation: current)
                let restored = try await store.restore()
                guard self.generation == current, self.transportGeneration == transport else { return }
                for snapshot in restored { self.publish(snapshot) }
                self.transportReady = true
                self.wakeWorkers()
            } catch {
                self.storageFailed(error, generation: current)
            }
        }
    }

    func setForegroundActive(_ active: Bool) async {
        requestForegroundActive(active)
        await lifecycle?.value
    }

    func retryStorage() async {
        guard let uid = requestedUID, !authenticationFailed else { return }
        invalidateTransport()
        storageState = .loading
        let current = generation
        let transport = transportGeneration
        let previous = lifecycle
        let recovery = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.stopWorkers()
            guard self.generation == current else { return }
            await self.openAndRestore(uid: uid, generation: current, transport: transport)
        }
        lifecycle = recovery
        await recovery.value
    }

    /// A known acknowledgement is hidden until its durable deletion succeeds.
    func pendingMessages(chatID: String) -> [LocalOutgoingMessage] {
        let outgoing = snapshots[chatID]?.outgoing ?? []
        guard !acknowledgements.isEmpty else { return outgoing }
        return outgoing.filter { acknowledgements[$0.clientGeneratedID] == nil }
    }

    func saveDraft(chatID: String, text: String, editRevision: Int64, updatedAt: Date) async throws {
        guard let store, requestedUID != nil else { throw QueueError.storageUnavailable }
        let current = generation
        do {
            try await checkpoint(.saveDraft, generation: current)
            let snapshot = try await store.saveDraft(chatID: chatID, text: text, editRevision: editRevision, updatedAt: updatedAt)
            try checkGeneration(current)
            publish(snapshot)
        } catch {
            storageFailed(error, generation: current)
            throw error
        }
    }

    func enqueueText(chatID: String, text: String, clearedDraftRevision: Int64) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalStorageError.blankMessage }
        guard storageState == .ready, let store, let uid = requestedUID, !authenticationFailed else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        let id = UUID().uuidString
        let date = Date()
        do {
            try await checkpoint(.enqueue, generation: current)
            let snapshot = try await store.enqueueText(chatID: chatID, senderID: uid, clientGeneratedID: id, text: text, enqueuedAt: date, clearedDraftRevision: clearedDraftRevision)
            try checkGeneration(current)
            publish(snapshot)
            wakeWorker(chatID: chatID)
        } catch {
            storageFailed(error, generation: current)
            throw error
        }
    }

    func retry(chatID: String, clientGeneratedID: String, scope: OutgoingRetryScope) async throws {
        guard storageState == .ready, let store, !authenticationFailed else { throw QueueError.storageUnavailable }
        let current = generation
        do {
            try await checkpoint(.retry, generation: current)
            let snapshot = try await store.retry(chatID: chatID, clientGeneratedID: clientGeneratedID, scope: scope)
            try checkGeneration(current)
            publish(snapshot)
            wakeWorker(chatID: chatID)
        } catch {
            storageFailed(error, generation: current)
            throw error
        }
    }

    func acceptAcknowledgement(_ message: MessageResponse) async -> Bool {
        guard let store, let uid = requestedUID, !message.clientGeneratedId.isEmpty,
              message.sender.uid == uid else { return false }
        let known = snapshots[message.chatId]?.outgoing.first { $0.clientGeneratedID == message.clientGeneratedId }
        let retained = acknowledgements[message.clientGeneratedId]
        guard known.map({ matches(message, pending: $0) }) == true ||
                (retained?.chatId == message.chatId && retained?.sender.uid == message.sender.uid) else { return false }
        let current = generation
        await acknowledge(message, store: store, generation: current)
        return generation == current
    }

    private func openAndRestore(uid: Int32, generation current: UInt64, transport: UInt64) async {
        do {
            let local: ChahuaLocalStore
            if let store { local = store } else { local = try await localStoreFactory(uid) }
            try checkGeneration(current)
            store = local
            // Deletions precede interrupted-send recovery: never redispatch known delivery.
            for message in Array(acknowledgements.values) {
                try await checkpoint(.acknowledge, generation: current)
                let snapshot = try await local.acknowledge(chatID: message.chatId, clientGeneratedID: message.clientGeneratedId)
                try checkGeneration(current)
                publish(snapshot, acknowledging: message)
                acknowledgements[message.clientGeneratedId] = nil
                uncommittedFailures[message.clientGeneratedId] = nil
            }
            for pending in Array(uncommittedFailures.values) {
                try await checkpoint(.fail, generation: current)
                let snapshot = try await local.fail(chatID: pending.chatID, clientGeneratedID: pending.clientGeneratedID)
                try checkGeneration(current)
                publish(snapshot)
                uncommittedFailures[pending.clientGeneratedID] = nil
            }
            try await checkpoint(.restore, generation: current)
            let restored = try await local.restore()
            try checkGeneration(current)
            for snapshot in restored { publish(snapshot) }
            storageState = .ready
            if transportGeneration == transport { transportReady = true }
            wakeWorkers()
        } catch {
            storageFailed(error, generation: current)
        }
    }

    private func invalidateTransport() {
        transportGeneration &+= 1
        transportReady = false
        for worker in workers.values { worker.task.cancel() }
    }

    private func stopWorkers() async {
        let stopping = Array(workers.values)
        for worker in stopping { worker.task.cancel() }
        for worker in stopping { await worker.task.value }
    }

    private func wakeWorkers() {
        for chatID in snapshots.keys { wakeWorker(chatID: chatID) }
    }

    private func wakeWorker(chatID: String) {
        guard foregroundActive, transportReady, storageState == .ready, !authenticationFailed,
              workers[chatID] == nil, let store,
              let head = snapshots[chatID]?.outgoing.first(where: { acknowledgements[$0.clientGeneratedID] == nil }),
              head.state == .queued else { return }
        let current = generation
        let transport = transportGeneration
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(chatID: chatID, store: store, generation: current, transport: transport)
            if self.workers[chatID]?.id == id {
                self.workers[chatID] = nil
                // A retry/enqueue may have committed while the old worker was ending.
                self.wakeWorker(chatID: chatID)
            }
        }
        workers[chatID] = (id, task)
    }

    private func run(chatID: String, store: ChahuaLocalStore, generation current: UInt64, transport: UInt64) async {
        while canDispatch(generation: current, transport: transport) {
            let pending: LocalOutgoingMessage
            do {
                try await checkpoint(.claim, generation: current)
                guard canDispatch(generation: current, transport: transport) else { return }
                let claim = try await store.claimNext(chatID: chatID)
                guard generation == current else { return }
                publish(claim.snapshot)
                guard let message = claim.message, canDispatch(generation: current, transport: transport) else { return }
                pending = message
            } catch {
                storageFailed(error, generation: current)
                return
            }
            do {
                let response = try await apiClient.sendMessage(chatID: chatID, body: CreateMessageBody(messageType: .text, clientGeneratedId: pending.clientGeneratedID, message: pending.text))
                guard generation == current else { return }
                guard matches(response, pending: pending) else { throw QueueError.invalidAcknowledgement }
                // Even a socket-first success must emit this validated HTTP acknowledgement.
                await acknowledge(response, store: store, generation: current)
            } catch {
                guard generation == current, !Task.isCancelled, transportGeneration == transport else { return }
                let invalidToken: Bool
                if case APIError.invalidToken = error { invalidToken = true } else { invalidToken = false }
                if invalidToken {
                    authenticationFailed = true
                    for (otherChat, worker) in workers where otherChat != chatID { worker.task.cancel() }
                }
                if acknowledgements[pending.clientGeneratedID] == nil,
                   snapshots[chatID]?.outgoing.contains(where: { $0.clientGeneratedID == pending.clientGeneratedID }) == true {
                    uncommittedFailures[pending.clientGeneratedID] = pending
                    do {
                        try await checkpoint(.fail, generation: current)
                        let snapshot = try await store.fail(chatID: chatID, clientGeneratedID: pending.clientGeneratedID)
                        try checkGeneration(current)
                        publish(snapshot)
                        uncommittedFailures[pending.clientGeneratedID] = nil
                    } catch {
                        storageFailed(error, generation: current)
                    }
                }
                guard generation == current else { return }
                if invalidToken {
                    await onInvalidToken()
                    return
                }
                // A socket/history confirmation makes an obsolete HTTP error harmless.
                if snapshots[chatID]?.outgoing.contains(where: { $0.clientGeneratedID == pending.clientGeneratedID }) == true { return }
            }
        }
    }

    private func acknowledge(_ message: MessageResponse, store: ChahuaLocalStore, generation current: UInt64) async {
        acknowledgements[message.clientGeneratedId] = message
        uncommittedFailures[message.clientGeneratedId] = nil
        do {
            try await checkpoint(.acknowledge, generation: current)
            let snapshot = try await store.acknowledge(chatID: message.chatId, clientGeneratedID: message.clientGeneratedId)
            try checkGeneration(current)
            publish(snapshot, acknowledging: message)
            acknowledgements[message.clientGeneratedId] = nil
        } catch {
            guard generation == current else { return }
            storageFailed(error, generation: current)
            events.send(.acknowledged(snapshot: nil, message: message))
        }
        if generation == current { wakeWorker(chatID: message.chatId) }
    }

    private func matches(_ message: MessageResponse, pending: LocalOutgoingMessage) -> Bool {
        !message.clientGeneratedId.isEmpty && message.clientGeneratedId == pending.clientGeneratedID &&
            message.chatId == pending.chatID && message.sender.uid == pending.senderID
    }

    private func publish(_ snapshot: LocalConversationSnapshot, acknowledging message: MessageResponse? = nil) {
        let accepted = snapshots[snapshot.chatID].map { snapshot.revision >= $0.revision } ?? true
        if accepted { snapshots[snapshot.chatID] = snapshot }
        if let message {
            events.send(.acknowledged(snapshot: accepted ? snapshot : nil, message: message))
        } else if accepted {
            events.send(.snapshot(snapshot))
        }
    }

    private func canDispatch(generation current: UInt64, transport: UInt64) -> Bool {
        generation == current && transportGeneration == transport && !Task.isCancelled &&
            foregroundActive && transportReady && storageState == .ready && !authenticationFailed
    }

    private func checkpoint(_ operation: StorageOperation, generation current: UInt64) async throws {
        try await beforeStorageOperation?(operation)
        try checkGeneration(current)
    }

    private func checkGeneration(_ current: UInt64) throws {
        guard generation == current else { throw CancellationError() }
    }

    private func storageFailed(_ error: Error, generation current: UInt64) {
        guard generation == current else { return }
        storageState = .failed
    }
}
