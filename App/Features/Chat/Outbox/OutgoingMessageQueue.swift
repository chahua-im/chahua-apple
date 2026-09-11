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
    @Published private(set) var snapshots: [ConversationKey: LocalConversationSnapshot] = [:]
    @Published private(set) var attachmentProgress: [String: Double] = [:]
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
    private var workers: [ConversationKey: (id: UUID, task: Task<Void, Never>)] = [:]
    private var acknowledgements: [String: MessageResponse] = [:]
    private var uncommittedFailures: [String: LocalOutgoingMessage] = [:]
    private var attachmentWorkers: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var preparationWorker: (id: UUID, task: Task<Void, Never>)?
    private var preparingAttachmentID: String?
    private var importingConversations = Set<ConversationKey>()
    private var authenticationFailed = false
    private var fileCleanupTask: Task<Void, Never>?

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
        fileCleanupTask?.cancel()
        fileCleanupTask = nil
        let current = generation
        let transport = transportGeneration
        store = nil
        snapshots = [:]
        acknowledgements = [:]
        uncommittedFailures = [:]
        attachmentProgress = [:]
        importingConversations = []
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
    func pendingMessages(chatID: String, threadID: String? = nil) -> [LocalOutgoingMessage] {
        let outgoing = snapshots[ConversationKey(chatID: chatID, threadID: threadID)]?.outgoing ?? []
        guard !acknowledgements.isEmpty else { return outgoing }
        return outgoing.filter { acknowledgements[$0.clientGeneratedID] == nil }
    }

    func saveDraft(chatID: String, threadID: String? = nil, text: String, editRevision: Int64, updatedAt: Date, replyToMessage: MessagePreview? = nil) async throws {
        guard let store, requestedUID != nil else { throw QueueError.storageUnavailable }
        let current = generation
        do {
            try await checkpoint(.saveDraft, generation: current)
            let snapshot = try await store.saveDraft(chatID: chatID, threadID: threadID, text: text, editRevision: editRevision, updatedAt: updatedAt, replyToMessage: replyToMessage)
            try checkGeneration(current)
            publish(snapshot)
        } catch {
            storageFailed(error, generation: current)
            throw error
        }
    }

    func enqueueText(chatID: String, threadID: String? = nil, text: String, clearedDraftRevision: Int64, replyToMessage: MessagePreview? = nil) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftAttachments(chatID: chatID, threadID: threadID).isEmpty
        else { throw LocalStorageError.blankMessage }
        guard storageState == .ready, let store, let uid = requestedUID, !authenticationFailed,
            !importingConversations.contains(ConversationKey(chatID: chatID, threadID: threadID)) else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        let id = UUID().uuidString
        let date = Date()
        do {
            try await checkpoint(.enqueue, generation: current)
            let snapshot = try await store.enqueueText(chatID: chatID, threadID: threadID, senderID: uid, clientGeneratedID: id, text: text, enqueuedAt: date, clearedDraftRevision: clearedDraftRevision, replyToMessage: replyToMessage)
            try checkGeneration(current)
            publish(snapshot)
            wakeWorker(key: snapshot.conversationKey)
        } catch {
            storageFailed(error, generation: current)
            throw error
        }
    }

    func retry(chatID: String, threadID: String? = nil, clientGeneratedID: String, scope: OutgoingRetryScope) async throws {
        guard storageState == .ready, let store, !authenticationFailed else { throw QueueError.storageUnavailable }
        let current = generation
        do {
            try await checkpoint(.retry, generation: current)
            let snapshot = try await store.retry(chatID: chatID, threadID: threadID, clientGeneratedID: clientGeneratedID, scope: scope)
            try checkGeneration(current)
            publish(snapshot)
            wakeWorker(key: snapshot.conversationKey)
        } catch {
            storageFailed(error, generation: current)
            throw error
        }
    }

    func acceptAcknowledgement(_ message: MessageResponse) async -> Bool {
        guard let store, let uid = requestedUID, !message.clientGeneratedId.isEmpty,
              message.sender.uid == uid else { return false }
        let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
        let known = snapshots[key]?.outgoing.first { $0.clientGeneratedID == message.clientGeneratedId }
        let retained = acknowledgements[message.clientGeneratedId]
        guard known.map({ matches(message, pending: $0) }) == true ||
                (retained?.chatId == message.chatId && retained?.replyRootId == message.replyRootId &&
                 retained?.sender.uid == message.sender.uid) else { return false }
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
                let snapshot = try await local.acknowledge(chatID: message.chatId, threadID: message.replyRootId, clientGeneratedID: message.clientGeneratedId)
                try checkGeneration(current)
                publish(snapshot, acknowledging: message)
                acknowledgements[message.clientGeneratedId] = nil
                uncommittedFailures[message.clientGeneratedId] = nil
            }
            for pending in Array(uncommittedFailures.values) {
                try await checkpoint(.fail, generation: current)
                let snapshot = try await local.fail(chatID: pending.chatID, threadID: pending.threadID, clientGeneratedID: pending.clientGeneratedID)
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
        for worker in attachmentWorkers.values { worker.task.cancel() }
        preparationWorker?.task.cancel()
    }

    private func stopWorkers() async {
        let stopping = Array(workers.values)
        for worker in stopping { worker.task.cancel() }
        for worker in stopping { await worker.task.value }
        if let preparationWorker { await preparationWorker.task.value }
        for worker in Array(attachmentWorkers.values) { await worker.task.value }
    }

    private func wakeWorkers() {
        for key in snapshots.keys { wakeWorker(key: key) }
        wakeAttachmentWorkers()
    }

    private func wakeWorker(key: ConversationKey) {
        guard foregroundActive, transportReady, storageState == .ready, !authenticationFailed,
              workers[key] == nil, let store,
              let head = snapshots[key]?.outgoing.first(where: { acknowledgements[$0.clientGeneratedID] == nil }),
              head.state == .queued, head.attachments.allSatisfy({ $0.isUploaded && $0.error == nil }) else { return }
        let current = generation
        let transport = transportGeneration
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(key: key, store: store, generation: current, transport: transport)
            if self.workers[key]?.id == id {
                self.workers[key] = nil
                // A retry/enqueue may have committed while the old worker was ending.
                self.wakeWorker(key: key)
            }
        }
        workers[key] = (id, task)
    }

    private func run(key: ConversationKey, store: ChahuaLocalStore, generation current: UInt64, transport: UInt64) async {
        while canDispatch(generation: current, transport: transport) {
            let pending: LocalOutgoingMessage
            do {
                try await checkpoint(.claim, generation: current)
                guard canDispatch(generation: current, transport: transport) else { return }
                let claim = try await store.claimNext(chatID: key.chatID, threadID: key.threadID)
                guard generation == current else { return }
                publish(claim.snapshot)
                guard let message = claim.message, canDispatch(generation: current, transport: transport) else { return }
                pending = message
            } catch {
                storageFailed(error, generation: current)
                return
            }
            do {
                let body = pending.body
                let response: MessageResponse
                if let threadID = pending.threadID {
                    response = try await apiClient.sendThreadMessage(chatID: pending.chatID, threadID: threadID, body: body)
                } else {
                    response = try await apiClient.sendMessage(chatID: pending.chatID, body: body)
                }
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
                    for (otherKey, worker) in workers where otherKey != key { worker.task.cancel() }
                }
                if acknowledgements[pending.clientGeneratedID] == nil,
                   snapshots[key]?.outgoing.contains(where: { $0.clientGeneratedID == pending.clientGeneratedID }) == true {
                    uncommittedFailures[pending.clientGeneratedID] = pending
                    do {
                        try await checkpoint(.fail, generation: current)
                        let snapshot = try await store.fail(chatID: key.chatID, threadID: key.threadID, clientGeneratedID: pending.clientGeneratedID)
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
                if snapshots[key]?.outgoing.contains(where: { $0.clientGeneratedID == pending.clientGeneratedID }) == true { return }
            }
        }
    }

    private func acknowledge(_ message: MessageResponse, store: ChahuaLocalStore, generation current: UInt64) async {
        acknowledgements[message.clientGeneratedId] = message
        uncommittedFailures[message.clientGeneratedId] = nil
        do {
            // Once validated, delivery belongs to this captured account store.
            // Finish its durable deletion even if scene teardown cancels the sender.
            let beforeCommit = beforeStorageOperation
            let commit = Task {
                try await beforeCommit?(.acknowledge)
                return try await store.acknowledge(
                    chatID: message.chatId, threadID: message.replyRootId,
                    clientGeneratedID: message.clientGeneratedId)
            }
            let snapshot = try await commit.value
            try checkGeneration(current)
            publish(snapshot, acknowledging: message)
            acknowledgements[message.clientGeneratedId] = nil
        } catch {
            guard generation == current else { return }
            storageFailed(error, generation: current)
            events.send(.acknowledged(snapshot: nil, message: message))
        }
        if generation == current { wakeWorker(key: ConversationKey(chatID: message.chatId, threadID: message.replyRootId)) }
    }

    private func matches(_ message: MessageResponse, pending: LocalOutgoingMessage) -> Bool {
        !message.clientGeneratedId.isEmpty && message.clientGeneratedId == pending.clientGeneratedID &&
            message.chatId == pending.chatID && message.replyRootId == pending.threadID &&
            message.sender.uid == pending.senderID
    }

    func draftAttachments(chatID: String, threadID: String? = nil) -> [LocalOutgoingAttachment] {
        snapshots[ConversationKey(chatID: chatID, threadID: threadID)]?.draft.attachments ?? []
    }

    func compressionEnabled(chatID: String, threadID: String? = nil) -> Bool {
        snapshots[ConversationKey(chatID: chatID, threadID: threadID)]?.draft.compressionEnabled ?? true
    }

    func canModifyTail(itemID: String, chatID: String, threadID: String? = nil) -> Bool {
        guard let snapshot = snapshots[ConversationKey(chatID: chatID, threadID: threadID)] else { return false }
        let tail = snapshot.composingItem ?? snapshot.outgoing.last
        return tail?.clientGeneratedID == itemID && tail?.dispatchClaimed == false
    }

    func importImages(urls: [URL], chatID: String, threadID: String? = nil) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard storageState == .ready, let store, let uid = requestedUID,
            !importingConversations.contains(key)
        else { throw QueueError.storageUnavailable }
        guard draftAttachments(chatID: chatID, threadID: threadID).count + urls.count <= 20 else {
            throw LocalStorageError.invalidAttachments
        }
        let current = generation
        importingConversations.insert(key)
        defer { if generation == current { importingConversations.remove(key) } }
        let snapshot = try await store.beginComposition(chatID: chatID, threadID: threadID, senderID: uid)
        try checkGeneration(current)
        publish(snapshot)
        guard let item = snapshot.composingItem else { throw LocalStorageError.staleDraft }
        let processor = OutgoingImageProcessor(directory: store.directory)
        for url in urls {
            let imported = try await processor.importImage(from: url, directory: store.directory, position: 0)
            try checkGeneration(current)
            guard let latest = snapshots[key]?.composingItem,
                latest.clientGeneratedID == item.clientGeneratedID
            else { throw LocalStorageError.staleDraft }
            var attachment = imported
            attachment.position = latest.attachments.count
            let updated = try await store.setCompositionAttachments(
                chatID: chatID, threadID: threadID, itemID: latest.clientGeneratedID,
                expectedRevision: latest.editRevision, attachments: latest.attachments + [attachment],
                compressionEnabled: latest.compressionEnabled)
            try checkGeneration(current)
            publish(updated)
        }
    }

    func removeAttachment(id: String, chatID: String, threadID: String? = nil) async throws {
        try await changeAttachments(chatID: chatID, threadID: threadID) { item in
            item.attachments.filter { $0.id != id }
        }
    }

    func reorderAttachments(ids: [String], chatID: String, threadID: String? = nil) async throws {
        try await changeAttachments(chatID: chatID, threadID: threadID) { item in
            guard ids.count == item.attachments.count, Set(ids).count == ids.count,
                Set(ids) == Set(item.attachments.map(\.id))
            else { throw LocalStorageError.invalidAttachments }
            let byID = Dictionary(uniqueKeysWithValues: item.attachments.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }
    }

    func setCompressionEnabled(_ enabled: Bool, chatID: String, threadID: String? = nil) async throws {
        try await changeAttachments(chatID: chatID, threadID: threadID, compression: enabled) { $0.attachments }
    }

    private func changeAttachments(
        chatID: String, threadID: String?, compression: Bool? = nil,
        transform: (LocalOutgoingMessage) throws -> [LocalOutgoingAttachment]
    ) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard storageState == .ready, let store, let item = snapshots[key]?.composingItem else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        let attachments = try transform(item)
        let snapshot = try await store.setCompositionAttachments(
            chatID: chatID, threadID: threadID, itemID: item.clientGeneratedID,
            expectedRevision: item.editRevision, attachments: attachments,
            compressionEnabled: compression ?? item.compressionEnabled)
        try checkGeneration(current)
        publish(snapshot)
    }

    func retryAttachment(id: String, chatID: String, threadID: String? = nil) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard storageState == .ready, let store, let snapshot = snapshots[key] else {
            throw QueueError.storageUnavailable
        }
        let items = snapshot.outgoing + (snapshot.composingItem.map { [$0] } ?? [])
        guard let item = items.first(where: { $0.attachments.contains { $0.id == id } }),
            var attachment = item.attachments.first(where: { $0.id == id }),
            !item.dispatchClaimed
        else { throw LocalStorageError.invalidAttachments }
        let current = generation
        attachment.error = nil
        let updated = try await store.checkpointAttachment(
            chatID: chatID, threadID: threadID, itemID: item.clientGeneratedID, attachment: attachment)
        try checkGeneration(current)
        publish(updated)
        if !item.isBlocked, item.state == .failed {
            try await retry(chatID: chatID, threadID: threadID, clientGeneratedID: item.clientGeneratedID, scope: .message)
        }
    }

    func blockTail(chatID: String, threadID: String? = nil, itemID: String, expectedRevision: Int64) async throws {
        guard storageState == .ready, let store else { throw QueueError.storageUnavailable }
        let current = generation
        let snapshot = try await store.blockTail(
            chatID: chatID, threadID: threadID, itemID: itemID, expectedRevision: expectedRevision)
        try checkGeneration(current)
        publish(snapshot)
    }

    func revokeTail(chatID: String, threadID: String? = nil, itemID: String, expectedRevision: Int64) async throws {
        guard storageState == .ready, let store else { throw QueueError.storageUnavailable }
        let current = generation
        let snapshot = try await store.revokeTail(
            chatID: chatID, threadID: threadID, itemID: itemID, expectedRevision: expectedRevision)
        try checkGeneration(current)
        publish(snapshot)
        wakeWorker(key: snapshot.conversationKey)
    }

    private var attachmentItems: [LocalOutgoingMessage] {
        snapshots.values.flatMap { snapshot in
            snapshot.outgoing + (snapshot.composingItem.map { [$0] } ?? [])
        }.sorted {
            if $0.isBlocked != $1.isBlocked { return !$0.isBlocked }
            if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
            return $0.clientGeneratedID < $1.clientGeneratedID
        }
    }

    private func currentAttachment(item: LocalOutgoingMessage, attachment: LocalOutgoingAttachment) -> LocalOutgoingAttachment? {
        guard let snapshot = snapshots[item.conversationKey],
            let current = (snapshot.outgoing + (snapshot.composingItem.map { [$0] } ?? []))
                .first(where: { $0.clientGeneratedID == item.clientGeneratedID }),
            !current.dispatchClaimed
        else { return nil }
        return current.attachments.first { $0.id == attachment.id && $0.generation == attachment.generation }
    }

    private func wakeAttachmentWorkers() {
        guard foregroundActive, transportReady, storageState == .ready, !authenticationFailed, let store else { return }
        let items = attachmentItems.filter { !$0.dispatchClaimed && $0.state != .failed }
        let current = generation
        let transport = transportGeneration
        if preparationWorker == nil,
            let item = items.first(where: { $0.attachments.contains { !$0.isUploaded && $0.preparedPath == nil && $0.error == nil } }),
            let attachment = item.attachments.first(where: { !$0.isUploaded && $0.preparedPath == nil && $0.error == nil })
        {
            let id = UUID()
            preparingAttachmentID = attachment.id
            preparationWorker = (id, Task { [weak self] in
                guard let self else { return }
                await self.prepareAttachment(attachment, item: item, store: store, generation: current, transport: transport)
                if self.preparationWorker?.id == id {
                    self.preparationWorker = nil
                    self.preparingAttachmentID = nil
                }
                self.wakeAttachmentWorkers()
            })
        }
        guard transportReady else { return }
        for item in items {
            for attachment in item.attachments where !attachment.isUploaded && attachment.preparedPath != nil && attachment.error == nil {
                guard attachmentWorkers.count < 2 else { return }
                guard attachmentWorkers[attachment.id] == nil else { continue }
                let id = UUID()
                attachmentWorkers[attachment.id] = (id, Task { [weak self] in
                    guard let self else { return }
                    await self.uploadAttachment(attachment, item: item, store: store, generation: current, transport: transport)
                    if self.attachmentWorkers[attachment.id]?.id == id {
                        self.attachmentWorkers[attachment.id] = nil
                        self.attachmentProgress[attachment.id] = nil
                    }
                    self.wakeAttachmentWorkers()
                    self.wakeWorker(key: item.conversationKey)
                })
            }
        }
    }

    private func prepareAttachment(
        _ attachment: LocalOutgoingAttachment, item: LocalOutgoingMessage, store: ChahuaLocalStore,
        generation current: UInt64, transport: UInt64
    ) async {
        do {
            let prepared = try await OutgoingImageProcessor(directory: store.directory)
                .prepare(attachment, compressionEnabled: item.compressionEnabled)
            guard canDispatch(generation: current, transport: transport),
                currentAttachment(item: item, attachment: attachment) != nil else { return }
            try await persistAttachment(prepared, item: item, store: store, generation: current)
        } catch {
            await attachmentFailed(error, attachment: attachment, item: item, store: store, generation: current, transport: transport)
        }
    }

    private func uploadAttachment(
        _ original: LocalOutgoingAttachment, item: LocalOutgoingMessage, store: ChahuaLocalStore,
        generation current: UInt64, transport: UInt64
    ) async {
        var attachment = original
        do {
            let config = try await apiClient.attachmentConfig()
            guard attachment.byteCount <= config.maxFileSizeBytes else {
                throw AttachmentWorkError.tooLarge(config.maxFileSizeBytes)
            }
            // Allocation belongs only to this attempt; only a successful PUT is durable.
            let allocation = try await apiClient.requestAttachmentUpload(
                fileName: attachment.fileName, contentType: attachment.mimeType, size: attachment.byteCount,
                width: attachment.width, height: attachment.height, order: attachment.position)
            guard canDispatch(generation: current, transport: transport),
                currentAttachment(item: item, attachment: attachment) != nil else { return }
            let slotID = attachment.id
            let slotGeneration = attachment.generation
            let path = attachment.uploadPath
            try await OutgoingAttachmentUploader(directory: store.directory).upload(
                file: URL(fileURLWithPath: path), allocation: allocation
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current,
                        self.currentAttachment(item: item, attachment: original)?.generation == slotGeneration
                    else { return }
                    let previous = self.attachmentProgress[slotID] ?? -1
                    if progress == 1 || abs(progress - previous) >= 0.01 {
                        self.attachmentProgress[slotID] = progress
                    }
                }
            }
            guard canDispatch(generation: current, transport: transport),
                currentAttachment(item: item, attachment: attachment) != nil else { return }
            attachment.attachmentID = allocation.attachmentId
            try await persistAttachment(attachment, item: item, store: store, generation: current)
        } catch {
            await attachmentFailed(error, attachment: attachment, item: item, store: store, generation: current, transport: transport)
        }
    }

    private func persistAttachment(
        _ attachment: LocalOutgoingAttachment, item: LocalOutgoingMessage, store: ChahuaLocalStore,
        generation current: UInt64
    ) async throws {
        do {
            let updated = try await store.checkpointAttachment(
                chatID: item.chatID, threadID: item.threadID, itemID: item.clientGeneratedID, attachment: attachment)
            try checkGeneration(current)
            publish(updated)
        } catch {
            storageFailed(error, generation: current)
            throw error
        }
    }

    private func attachmentFailed(
        _ error: Error, attachment: LocalOutgoingAttachment, item: LocalOutgoingMessage, store: ChahuaLocalStore,
        generation current: UInt64, transport: UInt64
    ) async {
        guard canDispatch(generation: current, transport: transport),
            currentAttachment(item: item, attachment: attachment) != nil,
            !(error is CancellationError)
        else { return }
        var failed = attachment
        failed.error = error.localizedDescription
        do {
            try await persistAttachment(failed, item: item, store: store, generation: current)
        } catch { return }
        if case APIError.invalidToken = error {
            authenticationFailed = true
            invalidateTransport()
            await onInvalidToken()
        }
    }

    private enum AttachmentWorkError: LocalizedError {
        case tooLarge(Int64)
        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes): "Image exceeds the server limit of \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
            }
        }
    }

    private func scheduleFileCleanup() {
        guard fileCleanupTask == nil, let store else { return }
        let current = generation
        fileCleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.generation == current else { return }
            self.fileCleanupTask = nil
            guard self.storageState == .ready, self.preparationWorker == nil,
                self.attachmentWorkers.isEmpty, self.importingConversations.isEmpty else {
                self.scheduleFileCleanup()
                return
            }
            let retained = Set(self.attachmentItems.flatMap(\.attachments).flatMap {
                [$0.sourcePath, $0.previewPath] + ($0.preparedPath.map { [$0] } ?? [])
            })
            // A grace period covers hosted pending-to-server preview handoff.
            // A fresh import has a unique path and a newer timestamp.
            try? await OutgoingFileCleanup.reclaim(
                directory: store.directory, retaining: retained, olderThan: Date().addingTimeInterval(-60))
        }
    }

    private func publish(_ snapshot: LocalConversationSnapshot, acknowledging message: MessageResponse? = nil) {
        let accepted = snapshots[snapshot.conversationKey].map { snapshot.revision >= $0.revision } ?? true
        if accepted {
            let previous = snapshots[snapshot.conversationKey]
            let oldSlots = (previous?.outgoing ?? []).flatMap(\.attachments)
                + (previous?.composingItem?.attachments ?? [])
            let newSlots = snapshot.outgoing.flatMap(\.attachments) + (snapshot.composingItem?.attachments ?? [])
            let currentGenerations = Dictionary(uniqueKeysWithValues: newSlots.map { ($0.id, $0.generation) })
            for slot in oldSlots where currentGenerations[slot.id] != slot.generation {
                attachmentWorkers[slot.id]?.task.cancel()
                if preparingAttachmentID == slot.id { preparationWorker?.task.cancel() }
                attachmentProgress[slot.id] = nil
            }
            snapshots[snapshot.conversationKey] = snapshot
        }
        if let message {
            events.send(.acknowledged(snapshot: accepted ? snapshot : nil, message: message))
        } else if accepted {
            events.send(.snapshot(snapshot))
        }
        if accepted {
            wakeAttachmentWorkers()
            scheduleFileCleanup()
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
        guard generation == current, !(error is CancellationError) else { return }
        if let error = error as? LocalStorageError {
            switch error {
            case .blankMessage, .staleDraft, .notTail, .dispatchAlreadyClaimed, .invalidAttachments:
                return
            case .unsupportedSchema, .corruptRecord:
                break
            }
        }
        storageState = .failed
    }
}
