import ChahuaAPI
import Combine
import Foundation
import OSLog

enum OutgoingStorageState: Equatable {
    case inactive, loading, ready, failed
}

enum OutgoingQueueEvent {
    case snapshot(LocalConversationSnapshot)
    case delivered(snapshot: LocalConversationSnapshot?, message: MessageResponse)
    case updated(snapshot: LocalConversationSnapshot?, message: MessageResponse)
    case deleted(snapshot: LocalConversationSnapshot?, message: MessageResponse)
}

enum IncomingOutgoingDisposition: Equatable {
    case unrelated, consumed, suppress
}

@MainActor
final class OutgoingMessageQueue: ObservableObject {
    private static let logger = Logger(subsystem: "app.chahua.chat", category: "outbox")

    enum StorageOperation: Equatable {
        case restore, saveDraft, enqueue, claim, fail, retry, acknowledge, edit, cancel, patch,
            delete
    }

    enum QueueError: LocalizedError {
        case storageUnavailable
        case invalidAcknowledgement
        case invalidForwardSources
        case unavailableEditTarget
        var errorDescription: String? {
            if case .unavailableEditTarget = self {
                return AppLanguage.localized(
                    "This queued message changed or is no longer available.")
            }
            return nil
        }
    }

    @Published private(set) var storageState: OutgoingStorageState = .inactive
    @Published private(set) var snapshots: [ConversationKey: LocalConversationSnapshot] = [:]
    @Published private(set) var attachmentProgress: [String: Double] = [:]
    let events = PassthroughSubject<OutgoingQueueEvent, Never>()
    /// ChatStore supplies account-fenced membership and speaking authorization.
    /// Authorization failures are durable failed sends, never storage failures.
    var authorizeWrite: (@MainActor (String, String?) async throws -> Void)?

    private let apiClient: any ChahuaAPIClient
    private let localStoreFactory: @Sendable (Int32) async throws -> ChahuaLocalStore
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    // A narrow fault-injection boundary; all persistence still uses the concrete store.
    private let beforeStorageOperation:
        (@MainActor @Sendable (StorageOperation) async throws -> Void)?
    private var store: ChahuaLocalStore?
    private var requestedUID: Int32?
    private var generation: UInt64 = 0
    private var transportGeneration: UInt64 = 0
    private var foregroundActive = false
    private var transportReady = false
    private var lifecycle: Task<Void, Never>?
    private var storageOperationCount = 0
    private var storageDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var workers: [ConversationKey: (id: UUID, task: Task<Void, Never>)] = [:]
    private var activeCreates: [UUID: LocalOutgoingMessage] = [:]
    private struct Confirmation: Equatable {
        let message: MessageResponse
        let published: Bool
    }
    private enum Recovery: Equatable {
        case create(Confirmation)
        case patch(MessageResponse, revision: Int64)
        case delete(MessageResponse)
    }
    private var acknowledgements: [String: Confirmation] = [:]
    private var recoveries: [String: Recovery] = [:]
    private var latestConfirmations: [String: MessageResponse] = [:]
    private var mutationWorkers: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var itemChains: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var finalizingItems = Set<String>()
    private var editSessions: [UUID: PendingEditSession] = [:]
    private var sessionOwnedSlots: [UUID: Set<String>] = [:]
    private var transientSlots: [String: LocalOutgoingAttachment] = [:]
    private var importingSessions = Set<UUID>()
    private struct DeletedIdentity: Hashable {
        let key: ConversationKey
        let clientID: String
        let serverID: MessageID
    }
    private var completedDeletions = Set<DeletedIdentity>()
    private var uncommittedFailures: [String: LocalOutgoingMessage] = [:]
    private var uncommittedRestrictions: [String: SpeakingMode] = [:]
    private struct MutationFailure {
        let key: ConversationKey
        let patchRevision: Int64?
        let retryable: Bool
    }
    private var uncommittedMutationFailures: [String: MutationFailure] = [:]
    private var pendingAudioAcknowledgements: [MessageID: MessageResponse] = [:]
    /// Publication can beat the HTTP acknowledgement; retain that fact only for active sends.
    private var inflightAudioPublications: [String: Bool] = [:]
    private var attachmentWorkers: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var activeAttachmentSlots: [UUID: LocalOutgoingAttachment] = [:]
    private var activeAttachmentTasks: [UUID: Task<Void, Never>] = [:]
    private var preparationWorker: (id: UUID, task: Task<Void, Never>)?
    private var preparingAttachmentID: String?
    private var attachmentMutationConversations = Set<ConversationKey>()
    private var authenticationFailed = false
    private var fileCleanupTask: Task<Void, Never>?

    init(
        apiClient: any ChahuaAPIClient,
        localStoreFactory: @escaping @Sendable (Int32) async throws -> ChahuaLocalStore,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void,
        beforeStorageOperation: (@MainActor @Sendable (StorageOperation) async throws -> Void)? =
            nil
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
        let previousStore = store
        store = nil
        snapshots = [:]
        acknowledgements = [:]
        recoveries = [:]
        latestConfirmations = [:]
        completedDeletions = []
        let abandonedImports = Array(transientSlots.values)
        if let previousStore {
            releaseTransientFiles(abandonedImports, directory: previousStore.directory)
        }
        transientSlots = [:]
        for session in editSessions.values { session.invalidate() }
        editSessions = [:]
        sessionOwnedSlots = [:]
        importingSessions = []
        itemChains = [:]
        finalizingItems = []
        uncommittedFailures = [:]
        uncommittedRestrictions = [:]
        uncommittedMutationFailures = [:]
        pendingAudioAcknowledgements = [:]
        inflightAudioPublications = [:]
        attachmentProgress = [:]
        attachmentMutationConversations = []
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
                active, self.storageState == .ready, let store = self.store
            else { return }
            do {
                try await self.checkpoint(.restore, generation: current)
                let restored = try await self.storageOperation { try await store.restore() }
                guard self.generation == current, self.transportGeneration == transport else {
                    return
                }
                for snapshot in restored { self.publish(snapshot) }
                await self.finalizeCleanRows(store: store, generation: current)
                self.transportReady = true
                self.wakeWorkers()
            } catch {
                self.storageFailed(error, operation: "foreground restore", generation: current)
            }
        }
    }

    func setForegroundActive(_ active: Bool) async {
        requestForegroundActive(active)
        await lifecycle?.value
    }

    /// Reconnect reconciliation can affirm publication without replaying an unknown create.
    func resynchronizePublications() {
        publicationProbes.removeAll(keepingCapacity: true)
        wakeMutationWorkers()
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

    /// Confirmed lease-only rows are ordinary server messages, not duplicate pending bubbles.
    func pendingMessages(chatID: String, threadID: String? = nil) -> [LocalOutgoingMessage] {
        (snapshots[ConversationKey(chatID: chatID, threadID: threadID)]?.outgoing ?? []).filter {
            !$0.isCancelled && !isCompletedDeletionForItem($0)
                && ($0.confirmedMessage == nil || $0.editRevision > $0.acknowledgedRevision)
                && !(acknowledgements[$0.clientGeneratedID] != nil
                    && $0.editRevision <= ($0.frozenCreate?.revision ?? $0.editRevision))
        }
    }

    func failedCancellationIDs(chatID: String, threadID: String? = nil) -> [String] {
        (snapshots[ConversationKey(chatID: chatID, threadID: threadID)]?.outgoing ?? [])
            .filter { $0.isCancelled && $0.state == .failed }.map(\.clientGeneratedID)
    }

    func saveDraft(
        chatID: String, threadID: String? = nil, text: String, editRevision: Int64, updatedAt: Date,
        replyToMessage: MessagePreview? = nil
    ) async throws {
        let current = generation
        guard let store, requestedUID != nil else {
            logStorageError(
                QueueError.storageUnavailable, operation: "save draft (storage unavailable)",
                generation: current)
            throw QueueError.storageUnavailable
        }
        do {
            try await checkpoint(.saveDraft, generation: current)
            let snapshot = try await storageOperation {
                try await store.saveDraft(
                    chatID: chatID, threadID: threadID, text: text, editRevision: editRevision,
                    updatedAt: updatedAt, replyToMessage: replyToMessage)
            }
            try checkGeneration(current)
            publish(snapshot)
        } catch {
            // Autosave is best-effort; durable outbox work must remain dispatchable.
            logStorageError(error, operation: "save draft", generation: current)
            throw error
        }
    }

    func enqueueText(
        chatID: String, threadID: String? = nil, text: String, clearedDraftRevision: Int64,
        replyToMessage: MessagePreview? = nil
    ) async throws {
        guard
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draftAttachments(chatID: chatID, threadID: threadID).isEmpty
        else { throw LocalStorageError.blankMessage }
        guard storageState == .ready, let store, let uid = requestedUID, !authenticationFailed,
            !attachmentMutationConversations.contains(
                ConversationKey(chatID: chatID, threadID: threadID))
        else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        let id = UUID().uuidString
        let date = Date()
        do {
            try await checkpoint(.enqueue, generation: current)
            let snapshot = try await storageOperation {
                try await store.enqueueText(
                    chatID: chatID, threadID: threadID, senderID: uid, clientGeneratedID: id,
                    text: text, enqueuedAt: date, clearedDraftRevision: clearedDraftRevision,
                    replyToMessage: replyToMessage)
            }
            try checkGeneration(current)
            publish(snapshot)
            wakeWorker(key: snapshot.conversationKey)
        } catch {
            storageFailed(error, operation: "enqueue text", generation: current)
            throw error
        }
    }

    /// Persists a text send without consuming the conversation's current draft.
    /// Notification replies use this path because their system-owned input must
    /// never alter text or attachments already being composed in the app.
    func enqueueIndependentText(
        chatID: String, threadID: String? = nil, text: String
    ) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalStorageError.blankMessage
        }
        guard storageState == .ready, let store, let uid = requestedUID, !authenticationFailed
        else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        do {
            try await checkpoint(.enqueue, generation: current)
            let snapshot = try await storageOperation {
                try await store.enqueueIndependentText(
                    chatID: chatID, threadID: threadID, senderID: uid,
                    clientGeneratedID: UUID().uuidString,
                    text: text, enqueuedAt: Date())
            }
            try checkGeneration(current)
            publish(snapshot)
            wakeWorker(key: snapshot.conversationKey)
        } catch {
            storageFailed(error, operation: "enqueue independent text", generation: current)
            throw error
        }
    }

    /// Server-acknowledged audio remains selectable before its publication event/history row.
    var acknowledgedPendingAudioMessages: [MessageResponse] {
        pendingAudioAcknowledgements.values.filter { message in
            let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
            return !isCompletedDeletion(message)
                && snapshots[key]?.outgoing.first(where: {
                    $0.clientGeneratedID == message.clientGeneratedId
                })?.isCancelled != true
        }.sorted { $0.id < $1.id }
    }

    func forwardPlaceholderReason(for source: MessageResponse, merging: Bool) -> String? {
        if source.messageType == .audio,
            pendingAudioAcknowledgements[source.id]?.chatId == source.chatId
        {
            return "pendingAudio"
        }
        if merging, source.messageType == .forwarded,
            source.forwardedPreview?.containsForwardedMessages == true
        {
            return "nestedForward"
        }
        return nil
    }

    /// Forwards are independent operations: destination text, reply and uploads stay untouched.
    func enqueueForward(
        chatID: String, threadID: String? = nil, sources: [MessageResponse],
        allowPlaceholders: Bool = false
    ) async throws {
        guard let first = sources.first, sources.count <= 100,
            Set(sources.map(\.id)).count == sources.count,
            sources.allSatisfy({
                $0.chatId == first.chatId && !$0.isDeleted
                    && $0.messageType != .system && $0.messageType != .invite
            })
        else { throw QueueError.invalidForwardSources }
        guard storageState == .ready, let store, let uid = requestedUID, !authenticationFailed
        else { throw QueueError.storageUnavailable }
        let current = generation
        // Consent and content are captured once. Retries read only this durable request.
        let captured = sources.sorted { $0.id < $1.id }.map { source in
            if allowPlaceholders,
                let reason = forwardPlaceholderReason(for: source, merging: sources.count > 1)
            {
                return ForwardPlaceholderProjection.replacing(source, reason: reason)
            }
            return source
        }
        let request = LocalForwardRequest(
            sourceChatID: first.chatId, sources: captured, allowPlaceholders: allowPlaceholders)
        do {
            try await checkpoint(.enqueue, generation: current)
            try Task.checkCancellation()
            let snapshot = try await storageOperation {
                try await store.enqueueForward(
                    chatID: chatID, threadID: threadID, senderID: uid, request: request)
            }
            try checkGeneration(current)
            publish(snapshot)
            wakeWorker(key: snapshot.conversationKey)
        } catch {
            storageFailed(error, operation: "enqueue forward", generation: current)
            throw error
        }
    }

    func enqueueSticker(
        chatID: String, threadID: String? = nil, sticker: MessageStickerResponse,
        replyToMessage: MessagePreview? = nil
    ) async throws {
        guard storageState == .ready, let store, let uid = requestedUID, !authenticationFailed
        else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        let id = UUID().uuidString
        let date = Date()
        do {
            try await checkpoint(.enqueue, generation: current)
            let snapshot = try await storageOperation {
                try await store.enqueueSticker(
                    chatID: chatID, threadID: threadID, senderID: uid, clientGeneratedID: id,
                    sticker: sticker, enqueuedAt: date, replyToMessage: replyToMessage)
            }
            try checkGeneration(current)
            publish(snapshot)
            wakeWorker(key: snapshot.conversationKey)
        } catch {
            storageFailed(error, operation: "enqueue sticker", generation: current)
            throw error
        }
    }

    func enqueueVoice(
        chatID: String, threadID: String? = nil, fileURL: URL, replyToMessage: MessagePreview? = nil
    ) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard storageState == .ready, let store, let uid = requestedUID, !authenticationFailed,
            !attachmentMutationConversations.contains(key)
        else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        attachmentMutationConversations.insert(key)
        defer {
            if generation == current {
                attachmentMutationConversations.remove(key)
                scheduleFileCleanup()
            }
        }
        // Keep the recorder's source intact until both the account copy and row are durable.
        let attachment = try await OutgoingVoiceFiles.importVoice(
            from: fileURL, directory: store.directory)
        try checkGeneration(current)
        try Task.checkCancellation()
        do {
            try await checkpoint(.enqueue, generation: current)
            let snapshot = try await storageOperation {
                try await store.enqueueVoice(
                    chatID: chatID, threadID: threadID, senderID: uid,
                    clientGeneratedID: UUID().uuidString,
                    attachment: attachment, enqueuedAt: Date(), replyToMessage: replyToMessage)
            }
            try checkGeneration(current)
            publish(snapshot)
            wakeWorker(key: key)
        } catch {
            storageFailed(error, operation: "enqueue voice", generation: current)
            throw error
        }
    }

    func retry(
        chatID: String, threadID: String? = nil, clientGeneratedID: String,
        scope: OutgoingRetryScope
    ) async throws {
        guard storageState == .ready, let store, !authenticationFailed else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        if snapshots[ConversationKey(chatID: chatID, threadID: threadID)]?.outgoing
            .first(where: { $0.clientGeneratedID == clientGeneratedID })?.isCancelled != true
        {
            try await authorizeWrite?(chatID, threadID)
        }
        try checkGeneration(current)
        do {
            try await checkpoint(.retry, generation: current)
            let snapshot = try await storageOperation {
                try await store.retry(
                    chatID: chatID, threadID: threadID, clientGeneratedID: clientGeneratedID,
                    scope: scope)
            }
            try checkGeneration(current)
            publish(snapshot)
            mutationWorkers[clientGeneratedID]?.task.cancel()
            wakeWorkers()
        } catch {
            storageFailed(error, operation: "retry message", generation: current)
            throw error
        }
    }

    /// Successful authenticated source reads and WS publication provide affirmative finality.
    func acceptPublishedForwardSource(_ message: MessageResponse) {
        trackPublication(message)
        let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
        if snapshots[key]?.outgoing.contains(where: {
            $0.clientGeneratedID == message.clientGeneratedId && !$0.isPublished
        }) == true {
            let current = generation
            Task {
                guard generation == current else { return }
                _ = await acceptAcknowledgement(message, published: true)
            }
        }
    }

    private func trackPublication(_ message: MessageResponse) {
        guard message.messageType == .audio, message.sender.uid == requestedUID else { return }
        if pendingAudioAcknowledgements[message.id]?.chatId == message.chatId {
            pendingAudioAcknowledgements[message.id] = nil
        }
        if inflightAudioPublications[message.clientGeneratedId] != nil {
            inflightAudioPublications[message.clientGeneratedId] = true
        }
    }

    func acceptAcknowledgement(
        _ message: MessageResponse, published: Bool = true
    ) async -> IncomingOutgoingDisposition {
        if message.isDeleted { return await acceptDeletion(message) }
        let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
        if isCompletedDeletion(message) { return .suppress }
        guard let store, let uid = requestedUID, !message.clientGeneratedId.isEmpty,
            message.sender.uid == uid
        else { return .unrelated }
        if published { trackPublication(message) }
        let known = snapshots[key]?.outgoing.first {
            $0.clientGeneratedID == message.clientGeneratedId
        }
        let retained = acknowledgements[message.clientGeneratedId]?.message
        guard
            known.map({ matches(message, pending: $0) }) == true
                || (retained?.chatId == message.chatId
                    && retained?.replyRootId == message.replyRootId
                    && retained?.sender.uid == message.sender.uid)
        else { return .unrelated }
        let current = generation
        if let patch = known?.claimedPatch, published,
            (message.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == patch.text,
            message.attachments.map(\.id) == patch.attachmentIDs
        {
            await acknowledgePatch(
                message, revision: patch.revision, store: store, generation: current)
        } else {
            await acknowledge(message, published: published, store: store, generation: current)
        }
        guard generation == current else { return .suppress }
        let latest = snapshots[key]?.outgoing.first {
            $0.clientGeneratedID == message.clientGeneratedId
        }
        if isCompletedDeletion(message) || latest?.isCancelled == true
            || latest.map({ $0.editRevision > $0.acknowledgedRevision }) == true
        {
            return .suppress
        }
        return .consumed
    }

    func acceptDeletion(_ message: MessageResponse) async -> IncomingOutgoingDisposition {
        if isCompletedDeletion(message) { return .suppress }
        let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
        guard let store,
            let item = snapshots[key]?.outgoing.first(where: {
                matches(message, pending: $0)
                    || ($0.confirmedMessage?.id == message.id && $0.chatID == message.chatId
                        && $0.threadID == message.replyRootId && $0.senderID == message.sender.uid)
            })
        else {
            // A clean row can have finalized while its POST response is still held.
            // Ordinary ChatStore deletion owns this event, but the queue must fence
            // that transport's older success and any held history snapshot.
            if let confirmed = latestConfirmations.values.first(where: {
                $0.id == message.id && $0.chatId == message.chatId
                    && $0.replyRootId == message.replyRootId && $0.sender.uid == message.sender.uid
            }) {
                rememberDeletion(message, clientID: confirmed.clientGeneratedId)
            }
            return .unrelated
        }
        let current = generation
        rememberDeletion(message, clientID: item.clientGeneratedID)
        invalidateSessions(clientID: item.clientGeneratedID)
        recoveries[item.clientGeneratedID] = .delete(message)
        do {
            try await serialized(item.clientGeneratedID) {
                try await self.checkpoint(.delete, generation: current)
                if item.confirmedMessage == nil {
                    _ = try await store.acceptCreate(message, published: true)
                    try self.checkGeneration(current)
                }
                let transition = try await store.acceptDelete(
                    chatID: key.chatID, threadID: key.threadID, itemID: item.clientGeneratedID)
                try self.checkGeneration(current)
                self.publish(transition.snapshot, notify: false)
                self.events.send(.deleted(snapshot: transition.snapshot, message: message))
                self.recoveries[item.clientGeneratedID] = nil
            }
        } catch {
            storageFailed(error, operation: "accept deletion", generation: current)
            if generation == current { events.send(.deleted(snapshot: nil, message: message)) }
        }
        return .consumed
    }

    private func isCompletedDeletion(_ message: MessageResponse) -> Bool {
        let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
        return completedDeletions.contains {
            $0.key == key
                && ($0.serverID == message.id
                    || (!message.clientGeneratedId.isEmpty
                        && $0.clientID == message.clientGeneratedId))
        }
    }

    private func rememberDeletion(_ message: MessageResponse, clientID: String? = nil) {
        completedDeletions.insert(
            DeletedIdentity(
                key: ConversationKey(chatID: message.chatId, threadID: message.replyRootId),
                clientID: clientID ?? message.clientGeneratedId, serverID: message.id))
    }

    private func openAndRestore(uid: Int32, generation current: UInt64, transport: UInt64) async {
        var operation = "open store"
        do {
            let local: ChahuaLocalStore
            if let store { local = store } else { local = try await localStoreFactory(uid) }
            try checkGeneration(current)
            store = local
            for (clientID, recovery) in Array(recoveries) {
                operation = "replay outgoing response"
                try await checkpoint(.acknowledge, generation: current)
                let transition: LocalOutgoingTransition
                switch recovery {
                case .create(let confirmation):
                    transition = try await local.acceptCreate(
                        confirmation.message, published: confirmation.published)
                case .patch(let message, let revision):
                    transition = try await local.acceptPatch(
                        message, itemID: clientID, revision: revision)
                case .delete(let message):
                    _ = try await local.acceptCreate(message, published: true)
                    transition = try await local.acceptDelete(
                        chatID: message.chatId, threadID: message.replyRootId, itemID: clientID)
                }
                try checkGeneration(current)
                publish(transition.snapshot, notify: false)
                switch recovery {
                case .create(let confirmation):
                    emitConfirmation(
                        confirmation.message, snapshot: transition.snapshot, update: false)
                case .patch(let message, _):
                    emitConfirmation(message, snapshot: transition.snapshot, update: true)
                case .delete(let message):
                    rememberDeletion(message)
                    events.send(.deleted(snapshot: transition.snapshot, message: message))
                }
                clearRecovery(recovery, clientID: clientID)
                acknowledgements[clientID] = nil
                uncommittedFailures[clientID] = nil
                uncommittedMutationFailures[clientID] = nil
            }
            for pending in Array(uncommittedFailures.values) {
                operation = "replay send failure"
                try await checkpoint(.fail, generation: current)
                let snapshot = try await local.fail(
                    chatID: pending.chatID, threadID: pending.threadID,
                    clientGeneratedID: pending.clientGeneratedID,
                    speakingRestriction: uncommittedRestrictions[pending.clientGeneratedID])
                try checkGeneration(current)
                publish(snapshot)
                uncommittedFailures[pending.clientGeneratedID] = nil
                uncommittedRestrictions[pending.clientGeneratedID] = nil
            }
            for (clientID, failure) in Array(uncommittedMutationFailures) {
                operation = "replay mutation failure"
                try await checkpoint(.fail, generation: current)
                let snapshot = try await local.failMutation(
                    chatID: failure.key.chatID, threadID: failure.key.threadID,
                    itemID: clientID, patchRevision: failure.patchRevision,
                    retryable: failure.retryable)
                try checkGeneration(current)
                publish(snapshot)
                uncommittedMutationFailures[clientID] = nil
            }
            operation = "restore"
            try await checkpoint(.restore, generation: current)
            let restored = try await local.restore()
            try checkGeneration(current)
            for snapshot in restored { publish(snapshot) }
            await finalizeCleanRows(store: local, generation: current)
            storageState = .ready
            Self.logger.info("Outbox storage restored; queue ready")
            if transportGeneration == transport { transportReady = true }
            wakeWorkers()
        } catch {
            storageFailed(error, operation: operation, generation: current)
        }
    }

    private func invalidateTransport() {
        transportGeneration &+= 1
        transportReady = false
        publicationProbes = []
        for worker in workers.values { worker.task.cancel() }
        for worker in attachmentWorkers.values { worker.task.cancel() }
        for worker in mutationWorkers.values { worker.task.cancel() }
        preparationWorker?.task.cancel()
    }

    private func stopWorkers() async {
        // Cancellation is ownership invalidation, not a transport completion barrier.
        // Late requests retain their own file leases and are generation-fenced.
        for worker in workers.values { worker.task.cancel() }
        for worker in mutationWorkers.values { worker.task.cancel() }
        for worker in attachmentWorkers.values { worker.task.cancel() }
        preparationWorker?.task.cancel()
        workers = [:]
        mutationWorkers = [:]
        attachmentWorkers = [:]
        preparationWorker = nil
        preparingAttachmentID = nil
        // Retire SQLite work before reopening an account store. Network and codec
        // tasks are detached above; only already-issued local transactions and
        // registered per-item transitions participate in this finite barrier.
        await drainStorageOperations()
    }

    private func wakeWorkers() {
        for key in snapshots.keys { wakeWorker(key: key) }
        wakeMutationWorkers()
        wakeAttachmentWorkers()
    }

    private func wakeWorker(key: ConversationKey) {
        guard foregroundActive, transportReady, storageState == .ready, !authenticationFailed,
            workers[key] == nil, let store,
            let head = snapshots[key]?.outgoing.first(where: {
                !$0.isCancelled && $0.confirmedMessage == nil
                    && acknowledgements[$0.clientGeneratedID] == nil
            }),
            head.state == .queued, head.isReadyForDispatch
        else { return }
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

    private func run(
        key: ConversationKey, store: ChahuaLocalStore, generation current: UInt64, transport: UInt64
    ) async {
        while canDispatch(generation: current, transport: transport) {
            let pending: LocalOutgoingMessage
            do {
                try await checkpoint(.claim, generation: current)
                guard canDispatch(generation: current, transport: transport) else { return }
                let claim = try await storageOperation {
                    try await store.claimNext(chatID: key.chatID, threadID: key.threadID)
                }
                guard generation == current else { return }
                publish(claim.snapshot)
                guard let message = claim.message,
                    canDispatch(generation: current, transport: transport)
                else { return }
                pending = message
            } catch {
                storageFailed(error, operation: "claim message", generation: current)
                return
            }
            let fileLease = UUID()
            activeCreates[fileLease] = pending
            let awaitingAudioPublication =
                pending.forwardRequest == nil && pending.messageType == .audio
            if awaitingAudioPublication {
                inflightAudioPublications[pending.clientGeneratedID] = false
            }
            defer {
                activeCreates[fileLease] = nil
                if generation == current && transportGeneration == transport {
                    inflightAudioPublications[pending.clientGeneratedID] = nil
                }
            }
            do {
                try await authorizeWrite?(pending.chatID, pending.threadID)
                try checkGeneration(current)
                guard canDispatch(generation: current, transport: transport) else { return }
                let response: MessageResponse
                if let forward = pending.frozenCreate?.forwardRequest ?? pending.forwardRequest {
                    if forward.messageIDs.count == 1, let sourceID = forward.messageIDs.first {
                        response = try await apiClient.forwardMessage(
                            chatID: pending.chatID, messageID: sourceID,
                            body: ForwardMessageBody(
                                sourceChatId: forward.sourceChatID,
                                clientGeneratedId: pending.clientGeneratedID,
                                threadId: pending.threadID,
                                allowPlaceholders: forward.allowPlaceholders))
                    } else {
                        response = try await apiClient.forwardMessages(
                            chatID: pending.chatID,
                            body: ForwardMessagesBody(
                                sourceChatId: forward.sourceChatID, messageIds: forward.messageIDs,
                                clientGeneratedId: pending.clientGeneratedID,
                                threadId: pending.threadID,
                                allowPlaceholders: forward.allowPlaceholders))
                    }
                } else if let threadID = pending.threadID {
                    response = try await apiClient.sendThreadMessage(
                        chatID: pending.chatID, threadID: threadID, body: pending.body)
                } else {
                    response = try await apiClient.sendMessage(
                        chatID: pending.chatID, body: pending.body)
                }
                guard generation == current else { return }
                guard matches(response, pending: pending) else {
                    throw QueueError.invalidAcknowledgement
                }
                if awaitingAudioPublication,
                    inflightAudioPublications[pending.clientGeneratedID] == false
                {
                    pendingAudioAcknowledgements[response.id] = response
                }
                // Even a socket-first success must emit this validated HTTP acknowledgement.
                await acknowledge(
                    response,
                    published: !awaitingAudioPublication
                        || inflightAudioPublications[pending.clientGeneratedID] == true,
                    store: store, generation: current)
            } catch {
                guard generation == current, !Task.isCancelled, transportGeneration == transport
                else { return }
                // A validated WS success wins over every obsolete HTTP error, including 401.
                if isCompletedDeletionForItem(pending)
                    || acknowledgements[pending.clientGeneratedID] != nil
                    || snapshots[key]?.outgoing.first(where: {
                        $0.clientGeneratedID == pending.clientGeneratedID
                    }).map({ $0.confirmedMessage != nil || $0.isCancelled }) != false
                {
                    continue
                }
                let invalidToken: Bool
                if case APIError.invalidToken = error {
                    invalidToken = true
                } else {
                    invalidToken = false
                }
                if invalidToken {
                    authenticationFailed = true
                    for (otherKey, worker) in workers where otherKey != key { worker.task.cancel() }
                }
                if acknowledgements[pending.clientGeneratedID] == nil,
                    snapshots[key]?.outgoing.contains(where: {
                        $0.clientGeneratedID == pending.clientGeneratedID
                    }) == true
                {
                    uncommittedFailures[pending.clientGeneratedID] = pending
                    let restriction =
                        (error as? APIError)?.speakingRestriction
                        ?? (error as? SpeakingWriteError)?.speakingRestriction
                    uncommittedRestrictions[pending.clientGeneratedID] = restriction
                    do {
                        try await checkpoint(.fail, generation: current)
                        let snapshot = try await storageOperation {
                            try await store.fail(
                                chatID: key.chatID, threadID: key.threadID,
                                clientGeneratedID: pending.clientGeneratedID,
                                speakingRestriction: restriction)
                        }
                        try checkGeneration(current)
                        publish(snapshot)
                        uncommittedFailures[pending.clientGeneratedID] = nil
                        uncommittedRestrictions[pending.clientGeneratedID] = nil
                    } catch {
                        storageFailed(error, operation: "persist send failure", generation: current)
                    }
                }
                guard generation == current else { return }
                if invalidToken {
                    await onInvalidToken()
                    return
                }
                // A socket/history confirmation makes an obsolete HTTP error harmless.
                if snapshots[key]?.outgoing.contains(where: {
                    $0.clientGeneratedID == pending.clientGeneratedID
                }) == true {
                    return
                }
            }
        }
    }

    private func acknowledge(
        _ message: MessageResponse, published: Bool, store: ChahuaLocalStore,
        generation current: UInt64
    ) async {
        guard !isCompletedDeletion(message) else { return }
        let confirmation = Confirmation(message: message, published: published)
        acknowledgements[message.clientGeneratedId] = confirmation
        recordRecovery(.create(confirmation), clientID: message.clientGeneratedId)
        uncommittedFailures[message.clientGeneratedId] = nil
        uncommittedRestrictions[message.clientGeneratedId] = nil
        do {
            try await serialized(message.clientGeneratedId) {
                let beforeCommit = self.beforeStorageOperation
                let commit = Task {
                    try await beforeCommit?(.acknowledge)
                    return try await store.acceptCreate(message, published: published)
                }
                let transition = try await commit.value
                try self.checkGeneration(current)
                self.publish(transition.snapshot, notify: false)
                self.emitConfirmation(message, snapshot: transition.snapshot, update: false)
                self.acknowledgements[message.clientGeneratedId] = nil
                self.clearRecovery(.create(confirmation), clientID: message.clientGeneratedId)
                try await self.finalizeIfClean(
                    key: transition.snapshot.conversationKey, clientID: message.clientGeneratedId,
                    store: store, generation: current)
            }
        } catch {
            guard generation == current else { return }
            storageFailed(error, operation: "accept create", generation: current)
            emitConfirmation(message, snapshot: nil, update: false)
        }
        if generation == current { wakeWorkers() }
    }

    private func acknowledgePatch(
        _ message: MessageResponse, revision: Int64, store: ChahuaLocalStore,
        generation current: UInt64
    ) async {
        guard !isCompletedDeletion(message) else { return }
        recordRecovery(.patch(message, revision: revision), clientID: message.clientGeneratedId)
        do {
            try await serialized(message.clientGeneratedId) {
                try await self.checkpoint(.acknowledge, generation: current)
                let transition = try await store.acceptPatch(
                    message, itemID: message.clientGeneratedId, revision: revision)
                try self.checkGeneration(current)
                self.publish(transition.snapshot, notify: false)
                self.emitConfirmation(message, snapshot: transition.snapshot, update: true)
                self.clearRecovery(
                    .patch(message, revision: revision), clientID: message.clientGeneratedId)
                try await self.finalizeIfClean(
                    key: transition.snapshot.conversationKey, clientID: message.clientGeneratedId,
                    store: store, generation: current)
            }
        } catch { storageFailed(error, operation: "accept patch", generation: current) }
        if generation == current { wakeWorkers() }
    }

    private func recordRecovery(_ recovery: Recovery, clientID: String) {
        switch (recoveries[clientID], recovery) {
        case (.delete?, _), (.patch?, .create): return
        case (.patch(_, let old)?, .patch(_, let new)) where old > new: return
        default: recoveries[clientID] = recovery
        }
    }

    private func clearRecovery(_ recovery: Recovery, clientID: String) {
        if recoveries[clientID] == recovery { recoveries[clientID] = nil }
    }

    private func emitConfirmation(
        _ message: MessageResponse, snapshot: LocalConversationSnapshot?, update: Bool
    ) {
        guard !isCompletedDeletion(message) else {
            if let snapshot { events.send(.snapshot(snapshot)) }
            return
        }
        let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
        let item = snapshots[key]?.outgoing.first {
            $0.clientGeneratedID == message.clientGeneratedId
        }
        guard item?.isCancelled != true,
            item.map({
                $0.editRevision <= $0.acknowledgedRevision
                    || (snapshot == nil && !update
                        && $0.editRevision <= ($0.frozenCreate?.revision ?? $0.editRevision))
            }) != false
        else {
            if let snapshot { events.send(.snapshot(snapshot)) }
            return
        }
        let content =
            item?.confirmedMessage ?? latestConfirmations[message.clientGeneratedId] ?? message
        latestConfirmations[message.clientGeneratedId] = content
        if update {
            events.send(.updated(snapshot: snapshot, message: content))
        } else {
            events.send(.delivered(snapshot: snapshot, message: content))
        }
    }

    private func isCompletedDeletionForItem(_ item: LocalOutgoingMessage) -> Bool {
        completedDeletions.contains {
            $0.key == item.conversationKey && $0.clientID == item.clientGeneratedID
        }
    }

    private func storageOperation<T: Sendable>(
        _ operation: @MainActor () async throws -> T
    ) async rethrows -> T {
        storageOperationCount += 1
        defer { finishStorageOperation() }
        return try await operation()
    }

    private func finishStorageOperation() {
        storageOperationCount -= 1
        guard storageOperationCount == 0 else { return }
        while let waiter = storageDrainWaiters.popLast() { waiter.resume() }
    }

    private func drainStorageOperations() async {
        guard storageOperationCount != 0 else { return }
        await withCheckedContinuation { storageDrainWaiters.append($0) }
    }

    /// The chain covers durable transitions and leases, never transport waits.
    private func serialized<T: Sendable>(
        _ clientID: String, operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        // Register queued transitions before their first suspension, even when
        // an account handoff clears itemChains while the operation is waiting.
        storageOperationCount += 1
        defer { finishStorageOperation() }
        let previous = itemChains[clientID]?.task
        let id = UUID()
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        itemChains[clientID] = (id, Task { _ = await task.result })
        defer { if itemChains[clientID]?.id == id { itemChains[clientID] = nil } }
        return try await task.value
    }

    private func finalizeIfClean(
        key: ConversationKey, clientID: String, store: ChahuaLocalStore,
        generation current: UInt64
    ) async throws {
        try checkGeneration(current)
        guard
            !editSessions.values.contains(where: {
                $0.isValid && $0.clientGeneratedID == clientID
            }),
            let item = snapshots[key]?.outgoing.first(where: {
                $0.clientGeneratedID == clientID
            }), item.confirmedMessage != nil, item.isPublished, !item.isCancelled,
            item.claimedPatch == nil, item.editRevision <= item.acknowledgedRevision
        else { return }
        finalizingItems.insert(clientID)
        defer { finalizingItems.remove(clientID) }
        let snapshot = try await store.finalizeOutgoing(
            chatID: key.chatID, threadID: key.threadID, itemID: clientID,
            expectedRevision: item.editRevision)
        try checkGeneration(current)
        publish(snapshot)
    }

    private func finalizeCleanRows(store: ChahuaLocalStore, generation current: UInt64) async {
        let items = snapshots.values.flatMap(\.outgoing)
        for item in items
        where item.confirmedMessage != nil && !item.isCancelled
            && item.editRevision <= item.acknowledgedRevision
        {
            do {
                try await serialized(item.clientGeneratedID) {
                    try self.checkGeneration(current)
                    if let message = item.confirmedMessage {
                        self.emitConfirmation(
                            message, snapshot: self.snapshots[item.conversationKey],
                            update: item.acknowledgedRevision > 0)
                    }
                    try await self.finalizeIfClean(
                        key: item.conversationKey, clientID: item.clientGeneratedID,
                        store: store, generation: current)
                }
            } catch { storageFailed(error, operation: "finalize outgoing", generation: current) }
        }
    }

    func editOutgoing(
        chatID: String, threadID: String? = nil, itemID: String,
        expectedRevision: Int64, text: String, attachments: [LocalEditAttachment]
    ) async throws {
        guard storageState == .ready, let store, !authenticationFailed else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        guard let uid = requestedUID,
            snapshots[ConversationKey(chatID: chatID, threadID: threadID)]?.outgoing
                .first(where: { $0.clientGeneratedID == itemID })?.senderID == uid
        else { throw LocalStorageError.staleDraft }
        try await authorizeWrite?(chatID, threadID)
        try await serialized(itemID) {
            try await self.checkpoint(.edit, generation: current)
            let snapshot = try await store.editOutgoing(
                chatID: chatID, threadID: threadID, itemID: itemID,
                expectedRevision: expectedRevision, text: text, attachments: attachments)
            try self.checkGeneration(current)
            self.publish(snapshot)
            self.uncommittedMutationFailures[itemID] = nil
        }
        wakeWorkers()
    }

    func cancelOutgoing(
        chatID: String, threadID: String? = nil, itemID: String, expectedRevision: Int64
    ) async throws {
        guard storageState == .ready, let store, !authenticationFailed else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        guard let uid = requestedUID,
            snapshots[ConversationKey(chatID: chatID, threadID: threadID)]?.outgoing
                .first(where: { $0.clientGeneratedID == itemID })?.senderID == uid
        else { throw LocalStorageError.staleDraft }
        try await serialized(itemID) {
            try await self.checkpoint(.cancel, generation: current)
            let snapshot = try await store.cancelOutgoing(
                chatID: chatID, threadID: threadID, itemID: itemID,
                expectedRevision: expectedRevision)
            try self.checkGeneration(current)
            self.publish(snapshot)
            self.invalidateSessions(clientID: itemID)
            self.uncommittedMutationFailures[itemID] = nil
        }
        mutationWorkers[itemID]?.task.cancel()
        wakeWorkers()
    }

    private var publicationProbes = Set<String>()

    private func wakeMutationWorkers() {
        guard foregroundActive, transportReady, storageState == .ready, !authenticationFailed,
            let store
        else { return }
        for item in snapshots.values.flatMap(\.outgoing) {
            guard item.confirmedMessage != nil, mutationWorkers[item.clientGeneratedID] == nil,
                item.isCancelled || item.editRevision > item.acknowledgedRevision,
                item.state != .failed || item.mutationRetryable,
                item.isCancelled || item.claimedPatch != nil
                    || Self.localSlots(item).allSatisfy({ $0.isUploaded && $0.error == nil }),
                item.isPublished || !publicationProbes.contains(item.clientGeneratedID)
            else { continue }
            let current = generation
            let transport = transportGeneration
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runMutation(
                    item: item, store: store, generation: current,
                    transport: transport)
                if self.mutationWorkers[item.clientGeneratedID]?.id == id {
                    self.mutationWorkers[item.clientGeneratedID] = nil
                    self.wakeMutationWorkers()
                }
            }
            mutationWorkers[item.clientGeneratedID] = (id, task)
        }
    }

    private func runMutation(
        item original: LocalOutgoingMessage, store: ChahuaLocalStore,
        generation current: UInt64, transport: UInt64
    ) async {
        let key = original.conversationKey
        let clientID = original.clientGeneratedID
        var delay = 1
        while canDispatch(generation: current, transport: transport) {
            guard
                let item = snapshots[key]?.outgoing.first(where: {
                    $0.clientGeneratedID == clientID
                }), let confirmed = item.confirmedMessage,
                item.state != .failed || item.mutationRetryable
            else { return }
            if item.state == .failed && item.mutationRetryable {
                do {
                    try await serialized(clientID) {
                        try await self.checkpoint(.retry, generation: current)
                        let snapshot = try await store.retry(
                            chatID: key.chatID, threadID: key.threadID,
                            clientGeneratedID: clientID, scope: .message)
                        try self.checkGeneration(current)
                        self.publish(snapshot)
                    }
                    continue
                } catch {
                    storageFailed(
                        error, operation: "requeue transient mutation", generation: current)
                    return
                }
            }
            if !item.isPublished {
                guard publicationProbes.insert(clientID).inserted else { return }
                do {
                    let published = try await apiClient.getMessage(
                        chatID: item.chatID, messageID: confirmed.id)
                    guard canDispatch(generation: current, transport: transport),
                        matches(published, pending: item)
                    else { return }
                    _ = await acceptAcknowledgement(published, published: true)
                    continue
                } catch {
                    if case APIError.invalidToken = error {
                        authenticationFailed = true
                        invalidateTransport()
                        await onInvalidToken()
                    }
                    return
                }
            }
            var patch: LocalClaimedPatch?
            var isNetworkOperation = false
            do {
                if item.isCancelled {
                    isNetworkOperation = true
                    do {
                        try await apiClient.deleteMessage(
                            chatID: item.chatID, messageID: confirmed.id)
                    } catch {
                        guard Self.isMissingMessage(error) else { throw error }
                    }
                    guard generation == current else { return }
                    rememberDeletion(confirmed)
                    recoveries[clientID] = .delete(confirmed)
                    try await serialized(clientID) {
                        try await self.checkpoint(.delete, generation: current)
                        let transition = try await store.acceptDelete(
                            chatID: key.chatID, threadID: key.threadID, itemID: clientID)
                        try self.checkGeneration(current)
                        self.publish(transition.snapshot, notify: false)
                        self.events.send(
                            .deleted(snapshot: transition.snapshot, message: confirmed))
                        self.recoveries[clientID] = nil
                    }
                    return
                }
                try checkGeneration(current)
                patch = try await serialized(clientID) {
                    try await self.checkpoint(.patch, generation: current)
                    let claim = try await store.claimPatch(
                        chatID: key.chatID, threadID: key.threadID, itemID: clientID)
                    try self.checkGeneration(current)
                    self.publish(claim.snapshot)
                    return claim.patch
                }
                guard let patch else { return }
                isNetworkOperation = true
                try await authorizeWrite?(item.chatID, item.threadID)
                try checkGeneration(current)
                // Cancellation may commit while the claim was suspended.
                guard
                    snapshots[key]?.outgoing.first(where: {
                        $0.clientGeneratedID == clientID
                    })?.isCancelled == false
                else { continue }
                let response = try await apiClient.updateMessage(
                    chatID: item.chatID, messageID: confirmed.id,
                    body: UpdateMessageBody(message: patch.text, attachmentIds: patch.attachmentIDs)
                )
                guard generation == current else { return }
                guard matches(response, pending: item), response.id == confirmed.id else {
                    throw QueueError.invalidAcknowledgement
                }
                guard !isCompletedDeletion(response) else { return }
                guard
                    let latest = snapshots[key]?.outgoing.first(where: {
                        $0.clientGeneratedID == clientID
                    })
                else { return }
                if latest.acknowledgedRevision >= patch.revision { continue }
                recordRecovery(.patch(response, revision: patch.revision), clientID: clientID)
                try await serialized(clientID) {
                    try await self.checkpoint(.acknowledge, generation: current)
                    let transition = try await store.acceptPatch(
                        response, itemID: clientID, revision: patch.revision)
                    try self.checkGeneration(current)
                    self.publish(transition.snapshot, notify: false)
                    self.emitConfirmation(response, snapshot: transition.snapshot, update: true)
                    self.clearRecovery(
                        .patch(response, revision: patch.revision), clientID: clientID)
                    try await self.finalizeIfClean(
                        key: key, clientID: clientID, store: store, generation: current)
                }
                delay = 1
            } catch {
                guard generation == current else { return }
                if recoveries[clientID] != nil {
                    storageFailed(error, operation: "commit mutation response", generation: current)
                    if case .delete(let message) = recoveries[clientID] {
                        events.send(.deleted(snapshot: nil, message: message))
                    }
                    return
                }
                if !isNetworkOperation {
                    storageFailed(error, operation: "claim mutation", generation: current)
                    return
                }
                guard canDispatch(generation: current, transport: transport),
                    !(error is CancellationError)
                else { return }
                let latest = snapshots[key]?.outgoing.first { $0.clientGeneratedID == clientID }
                if latest == nil { return }
                if latest?.isCancelled == true && !item.isCancelled { continue }
                if let patch, (latest?.acknowledgedRevision ?? -1) >= patch.revision { continue }
                let retryable = Self.isTransientMutationError(error)
                let invalidToken: Bool
                if case APIError.invalidToken = error {
                    invalidToken = true
                    authenticationFailed = true
                    for worker in workers.values { worker.task.cancel() }
                    for (id, worker) in mutationWorkers where id != clientID {
                        worker.task.cancel()
                    }
                    for worker in attachmentWorkers.values { worker.task.cancel() }
                    preparationWorker?.task.cancel()
                } else {
                    invalidToken = false
                }
                let failure = MutationFailure(
                    key: key, patchRevision: item.isCancelled ? nil : patch?.revision,
                    retryable: retryable)
                uncommittedMutationFailures[clientID] = failure
                do {
                    try await serialized(clientID) {
                        try await self.checkpoint(.fail, generation: current)
                        let snapshot = try await store.failMutation(
                            chatID: key.chatID, threadID: key.threadID, itemID: clientID,
                            patchRevision: item.isCancelled
                                ? nil : (patch?.revision ?? item.claimedPatch?.revision),
                            retryable: retryable)
                        try self.checkGeneration(current)
                        self.publish(snapshot)
                        self.uncommittedMutationFailures[clientID] = nil
                    }
                } catch {
                    storageFailed(error, operation: "persist mutation failure", generation: current)
                    if invalidToken {
                        invalidateTransport()
                        await onInvalidToken()
                    }
                    return
                }
                if invalidToken {
                    invalidateTransport()
                    await onInvalidToken()
                    return
                }
                guard retryable else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(delay * 2, 30)
            }
        }
    }

    private static func isMissingMessage(_ error: Error) -> Bool {
        if case APIError.http(let status, _) = error { return status == 404 || status == 410 }
        return false
    }

    private static func isTransientMutationError(_ error: Error) -> Bool {
        if error is URLError { return true }
        switch error {
        case APIError.transport: return true
        case APIError.http(let status, _), APIError.invalidResponse(let status):
            return [408, 429, 500, 502, 503, 504].contains(status)
        default: return false
        }
    }

    func beginPendingEdit(_ pending: PendingOutgoingMessage) async throws -> PendingEditSession {
        let key = ConversationKey(chatID: pending.chatID, threadID: pending.threadID)
        guard storageState == .ready, !authenticationFailed, let uid = requestedUID,
            let item = snapshots[key]?.outgoing
                .first(where: { $0.clientGeneratedID == pending.clientGeneratedID }),
            item.senderID == uid, !item.isCancelled, item.forwardRequest == nil,
            item.messageType == .text,
            !finalizingItems.contains(item.clientGeneratedID)
        else { throw QueueError.unavailableEditTarget }
        let selection = item.intentAttachments ?? item.attachments.map(LocalEditAttachment.local)
        let session = PendingEditSession(
            conversationKey: key, clientGeneratedID: item.clientGeneratedID,
            accountGeneration: generation, capturedRevision: item.editRevision,
            initialText: item.text, initialAttachments: selection)
        // This registration must precede the first await: an acknowledgement cannot finalize it.
        editSessions[session.id] = session
        sessionOwnedSlots[session.id] = []
        do {
            try await authorizeWrite?(item.chatID, item.threadID)
            try await serialized(item.clientGeneratedID) {
                try self.validate(session)
                guard
                    let latest = self.snapshots[key]?.outgoing.first(where: {
                        $0.clientGeneratedID == item.clientGeneratedID
                    }), !latest.isCancelled, latest.editRevision == session.capturedRevision
                else { throw QueueError.unavailableEditTarget }
            }
            updateSessionWorkState()
            if let message = item.confirmedMessage {
                session.replaceUploadedSlots(serverAttachments: message.attachments)
            }
            return session
        } catch {
            endPendingEdit(session)
            throw error
        }
    }

    func submitPendingEdit(_ session: PendingEditSession, text: String) async throws {
        do {
            try validate(session)
            guard !importingSessions.contains(session.id) else {
                throw LocalStorageError.invalidAttachments
            }
            guard session.hasChanges(text: text) else { throw LocalStorageError.staleDraft }
            guard storageState == .ready, let store, !authenticationFailed else {
                throw QueueError.storageUnavailable
            }
            let current = generation
            let key = session.conversationKey
            try await authorizeWrite?(key.chatID, key.threadID)
            try await serialized(session.clientGeneratedID) {
                try self.validate(session)
                try await self.checkpoint(.edit, generation: current)
                try self.validate(session)
                let snapshot = try await store.editOutgoing(
                    chatID: key.chatID, threadID: key.threadID,
                    itemID: session.clientGeneratedID, expectedRevision: session.capturedRevision,
                    text: text, attachments: session.attachments)
                try self.checkGeneration(current)
                self.publish(snapshot)
                self.uncommittedMutationFailures[session.clientGeneratedID] = nil
            }
            try validate(session)
            wakeWorkers()
            // Durable intent now owns the selected import paths before the lease is released.
            endPendingEdit(session)
        } catch {
            if session.isValid {
                if case LocalStorageError.staleDraft = error {
                    session.setError(
                        AppLanguage.localized(
                            "This queued message changed or is no longer available."))
                } else {
                    session.setError(error.localizedDescription)
                }
            }
            throw error
        }
    }

    func endPendingEdit(_ session: PendingEditSession) {
        guard editSessions[session.id] === session else { return }
        let ownedIDs = sessionOwnedSlots[session.id] ?? []
        let durableIDs = Set(
            attachmentItems.filter { !$0.isCancelled }
                .flatMap { Self.localSlots($0) }.map(\.id))
        let imported = ownedIDs.subtracting(durableIDs).compactMap { transientSlots[$0] }
        for id in ownedIDs.intersection(durableIDs) { transientSlots[id] = nil }
        editSessions[session.id] = nil
        sessionOwnedSlots[session.id] = nil
        importingSessions.remove(session.id)
        session.invalidate()
        cancelUnreferencedAttachmentWorkers()
        if let store { releaseTransientFiles(imported, directory: store.directory) }
        scheduleFileCleanup()
        let current = generation
        guard let store else { return }
        Task {
            do {
                try await serialized(session.clientGeneratedID) {
                    try await self.finalizeIfClean(
                        key: session.conversationKey, clientID: session.clientGeneratedID,
                        store: store, generation: current)
                }
            } catch { storageFailed(error, operation: "release edit lease", generation: current) }
        }
    }

    private func validate(_ session: PendingEditSession) throws {
        guard session.isValid, session.accountGeneration == generation,
            editSessions[session.id] === session
        else { throw QueueError.unavailableEditTarget }
    }

    private func invalidateSessions(clientID: String) {
        for session in Array(editSessions.values) where session.clientGeneratedID == clientID {
            endPendingEdit(session)
        }
    }

    func importEditImages(urls: [URL], session: PendingEditSession) async throws {
        try validate(session)
        guard storageState == .ready, let store, !importingSessions.contains(session.id) else {
            throw QueueError.storageUnavailable
        }
        guard session.attachments.count + urls.count <= 20 else {
            throw LocalStorageError.invalidAttachments
        }
        importingSessions.insert(session.id)
        updateSessionWorkState()
        defer {
            importingSessions.remove(session.id)
            updateSessionWorkState()
            wakeAttachmentWorkers()
        }
        let processor = OutgoingImageProcessor(directory: store.directory)
        for url in urls {
            let imported = try await processor.importImage(
                from: url, directory: store.directory, position: session.attachments.count)
            do {
                try validate(session)
                try Task.checkCancellation()
                sessionOwnedSlots[session.id, default: []].insert(imported.id)
                transientSlots[imported.id] = imported
                session.replaceAttachments(session.attachments + [.local(imported)])
                session.setError(nil)
                wakeAttachmentWorkers()
            } catch {
                // A late import has no owner; remove only its unique account-owned directory.
                if let file = try? OutgoingImageFiles.file(
                    URL(fileURLWithPath: imported.sourcePath), directory: store.directory)
                {
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                }
                throw error
            }
        }
    }

    func removeEditAttachment(id: String, session: PendingEditSession) {
        guard (try? validate(session)) != nil else { return }
        session.replaceAttachments(session.attachments.filter { Self.slotID($0) != id })
        cancelUnreferencedAttachmentWorkers()
        updateSessionWorkState()
        scheduleFileCleanup()
        if let imported = transientSlots[id], let store {
            releaseTransientFiles([imported], directory: store.directory)
        }
    }

    func reorderEditAttachments(ids: [String], session: PendingEditSession) throws {
        try validate(session)
        guard ids.count == session.attachments.count, Set(ids).count == ids.count,
            Set(ids) == Set(session.attachments.map(Self.slotID))
        else { throw LocalStorageError.invalidAttachments }
        let byID = Dictionary(
            uniqueKeysWithValues: session.attachments.map { (Self.slotID($0), $0) })
        session.replaceAttachments(ids.compactMap { byID[$0] })
    }

    func retryEditAttachment(id: String, session: PendingEditSession) {
        guard (try? validate(session)) != nil,
            let selected = session.attachments.first(where: { Self.slotID($0) == id }),
            case .local(var slot) = selected
        else { return }
        slot.error = nil
        replaceSessionSlot(slot)
        if sessionOwnedSlots[session.id]?.contains(id) != true {
            Task {
                try? await retryAttachment(
                    id: id, chatID: session.conversationKey.chatID,
                    threadID: session.conversationKey.threadID)
            }
        }
        wakeAttachmentWorkers()
    }

    private static func slotID(_ selection: LocalEditAttachment) -> String {
        switch selection {
        case .local(let slot): slot.id
        case .server(let attachment): attachment.id
        }
    }

    private static func localSlots(_ item: LocalOutgoingMessage) -> [LocalOutgoingAttachment] {
        guard let intent = item.intentAttachments else { return item.attachments }
        return intent.compactMap { if case .local(let slot) = $0 { slot } else { nil } }
    }

    private func replaceSessionSlot(_ slot: LocalOutgoingAttachment) {
        for session in editSessions.values {
            session.replaceAttachments(
                session.attachments.map {
                    guard case .local(let old) = $0, old.id == slot.id,
                        old.generation == slot.generation
                    else { return $0 }
                    var merged = slot
                    merged.position = old.position
                    return .local(merged)
                })
        }
        updateSessionWorkState()
    }

    private func mergePublishedSlot(_ slot: LocalOutgoingAttachment) {
        for session in editSessions.values {
            session.replaceAttachments(
                session.attachments.map {
                    guard case .local(let old) = $0, old.id == slot.id,
                        old.generation == slot.generation
                    else { return $0 }
                    if old.isUploaded && !slot.isUploaded { return .local(old) }
                    if old.preparedPath != nil && slot.preparedPath == nil && slot.error == nil {
                        return .local(old)
                    }
                    var merged = slot
                    merged.position = old.position
                    return .local(merged)
                })
        }
        updateSessionWorkState()
    }

    private func updateSessionWorkState() {
        for session in editSessions.values {
            session.setUploading(
                importingSessions.contains(session.id)
                    || session.attachments.contains {
                        if case .local(let slot) = $0 {
                            return !slot.isUploaded && slot.error == nil
                        }
                        return false
                    })
        }
    }

    /// Only transient imports are eagerly destroyed. Borrowed slots remain owned by the send.
    private func releaseTransientFiles(_ slots: [LocalOutgoingAttachment], directory: URL) {
        guard !slots.isEmpty else { return }
        let ids = Set(slots.lazy.map(\.id))
        let readers = activeAttachmentSlots.compactMap { id, slot in
            ids.contains(slot.id) ? activeAttachmentTasks[id] : nil
        }
        Task {
            for task in readers { await task.value }
            let retained = Set(
                attachmentItems.filter { !$0.isCancelled }
                    .flatMap { Self.localSlots($0) }.map(\.id)
            )
            .union(editSessions.values.flatMap { $0.attachments.map(Self.slotID) })
            .union(activeCreates.values.flatMap { $0.attachments.map(\.id) })
            for slot in slots where !retained.contains(slot.id) {
                guard
                    let file = try? OutgoingImageFiles.file(
                        URL(fileURLWithPath: slot.sourcePath), directory: directory)
                else { continue }
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                transientSlots[slot.id] = nil
            }
        }
    }

    private func matches(_ message: MessageResponse, pending: LocalOutgoingMessage) -> Bool {
        !message.clientGeneratedId.isEmpty && message.clientGeneratedId == pending.clientGeneratedID
            && message.chatId == pending.chatID && message.replyRootId == pending.threadID
            && message.sender.uid == pending.senderID
    }

    func draftAttachments(chatID: String, threadID: String? = nil) -> [LocalOutgoingAttachment] {
        snapshots[ConversationKey(chatID: chatID, threadID: threadID)]?.draft.attachments ?? []
    }

    func compressionEnabled(chatID: String, threadID: String? = nil) -> Bool {
        snapshots[ConversationKey(chatID: chatID, threadID: threadID)]?.draft.compressionEnabled
            ?? true
    }

    func importImages(urls: [URL], chatID: String, threadID: String? = nil) async throws {
        try await importAttachments(urls: urls, chatID: chatID, threadID: threadID, asFiles: false)
    }

    func importFiles(urls: [URL], chatID: String, threadID: String? = nil) async throws {
        try await importAttachments(urls: urls, chatID: chatID, threadID: threadID, asFiles: true)
    }

    private func importAttachments(
        urls: [URL], chatID: String, threadID: String?, asFiles: Bool
    ) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard storageState == .ready, let store, let uid = requestedUID,
            !attachmentMutationConversations.contains(key)
        else { throw QueueError.storageUnavailable }
        guard draftAttachments(chatID: chatID, threadID: threadID).count + urls.count <= 20 else {
            throw LocalStorageError.invalidAttachments
        }
        let current = generation
        attachmentMutationConversations.insert(key)
        defer { if generation == current { attachmentMutationConversations.remove(key) } }
        let snapshot = try await storageOperation {
            try await store.beginComposition(
                chatID: chatID, threadID: threadID, senderID: uid)
        }
        try checkGeneration(current)
        publish(snapshot)
        guard let item = snapshot.composingItem else { throw LocalStorageError.staleDraft }
        let processor = OutgoingImageProcessor(directory: store.directory)
        for url in urls {
            let imported: LocalOutgoingAttachment
            if asFiles {
                imported = try await OutgoingFileImporter(directory: store.directory)
                    .importFile(from: url, position: 0)
            } else {
                imported = try await processor.importImage(
                    from: url, directory: store.directory, position: 0)
            }
            try checkGeneration(current)
            guard let latest = snapshots[key]?.composingItem,
                latest.clientGeneratedID == item.clientGeneratedID
            else { throw LocalStorageError.staleDraft }
            var attachment = imported
            attachment.position = latest.attachments.count
            let updated = try await storageOperation {
                try await store.setCompositionAttachments(
                    chatID: chatID, threadID: threadID, itemID: latest.clientGeneratedID,
                    expectedRevision: latest.editRevision,
                    attachments: latest.attachments + [attachment],
                    compressionEnabled: latest.compressionEnabled)
            }
            try checkGeneration(current)
            publish(updated)
        }
    }

    func discardDraftAttachments(chatID: String, threadID: String? = nil) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard storageState == .ready, !attachmentMutationConversations.contains(key) else {
            throw QueueError.storageUnavailable
        }
        guard snapshots[key]?.composingItem != nil else { return }
        try await changeAttachments(chatID: chatID, threadID: threadID) { _ in [] }
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

    func setCompressionEnabled(_ enabled: Bool, chatID: String, threadID: String? = nil)
        async throws
    {
        try await changeAttachments(chatID: chatID, threadID: threadID, compression: enabled) {
            $0.attachments
        }
    }

    private func changeAttachments(
        chatID: String, threadID: String?, compression: Bool? = nil,
        transform: (LocalOutgoingMessage) throws -> [LocalOutgoingAttachment]
    ) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard storageState == .ready, let store, let item = snapshots[key]?.composingItem,
            !attachmentMutationConversations.contains(key)
        else {
            throw QueueError.storageUnavailable
        }
        let current = generation
        // Imports span multiple awaits; exclude edits in both directions so an
        // in-flight import cannot append another slot after a successful discard.
        attachmentMutationConversations.insert(key)
        defer { if generation == current { attachmentMutationConversations.remove(key) } }
        let attachments = try transform(item)
        let snapshot = try await storageOperation {
            try await store.setCompositionAttachments(
                chatID: chatID, threadID: threadID, itemID: item.clientGeneratedID,
                expectedRevision: item.editRevision, attachments: attachments,
                compressionEnabled: compression ?? item.compressionEnabled)
        }
        try checkGeneration(current)
        publish(snapshot)
    }

    func retryAttachment(id: String, chatID: String, threadID: String? = nil) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard storageState == .ready, let store, let snapshot = snapshots[key] else {
            throw QueueError.storageUnavailable
        }
        let items = snapshot.outgoing + (snapshot.composingItem.map { [$0] } ?? [])
        guard let item = items.first(where: { Self.localSlots($0).contains { $0.id == id } }),
            var attachment = Self.localSlots(item).first(where: { $0.id == id }),
            !item.isCancelled
        else { throw LocalStorageError.invalidAttachments }
        let current = generation
        attachment.error = nil
        let updated = try await storageOperation {
            try await store.checkpointAttachment(
                chatID: chatID, threadID: threadID, itemID: item.clientGeneratedID,
                attachment: attachment)
        }
        try checkGeneration(current)
        publish(updated)
        if !item.isBlocked, item.state == .failed {
            try await retry(
                chatID: chatID, threadID: threadID, clientGeneratedID: item.clientGeneratedID,
                scope: .message)
        }
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

    private struct AttachmentWork: Sendable {
        let attachment: LocalOutgoingAttachment
        let compressionEnabled: Bool
    }

    private var attachmentWork: [AttachmentWork] {
        var seen = Set<String>()
        var work: [AttachmentWork] = []
        for item in attachmentItems where !item.isCancelled && item.state != .failed {
            for slot in Self.localSlots(item) where seen.insert(slot.id).inserted {
                work.append(
                    AttachmentWork(
                        attachment: slot,
                        compressionEnabled: item.compressionEnabled))
            }
        }
        for session in editSessions.values where session.isValid {
            for case .local(let slot) in session.attachments where seen.insert(slot.id).inserted {
                work.append(AttachmentWork(attachment: slot, compressionEnabled: true))
            }
        }
        return work
    }

    private func currentAttachment(_ work: AttachmentWork) -> LocalOutgoingAttachment? {
        if let slot = attachmentItems.lazy.filter({ !$0.isCancelled })
            .flatMap({ Self.localSlots($0) }).first(where: {
                $0.id == work.attachment.id && $0.generation == work.attachment.generation
            })
        {
            return slot
        }
        for session in editSessions.values where session.isValid {
            for case .local(let slot) in session.attachments
            where slot.id == work.attachment.id && slot.generation == work.attachment.generation {
                return slot
            }
        }
        return nil
    }

    private func cancelUnreferencedAttachmentWorkers() {
        let ids = Set(attachmentWork.map { $0.attachment.id })
        for (id, worker) in attachmentWorkers where !ids.contains(id) {
            worker.task.cancel()
            attachmentProgress[id] = nil
        }
        if let preparingAttachmentID, !ids.contains(preparingAttachmentID) {
            preparationWorker?.task.cancel()
        }
    }

    private func wakeAttachmentWorkers() {
        guard foregroundActive, transportReady, storageState == .ready, !authenticationFailed,
            let store
        else { return }
        let work = attachmentWork
        let current = generation
        let transport = transportGeneration
        if preparationWorker == nil,
            let candidate = work.first(where: {
                let slot = $0.attachment
                return !slot.isAudio && !slot.isUploaded && slot.preparedPath == nil
                    && slot.error == nil
            })
        {
            let id = UUID()
            activeAttachmentSlots[id] = candidate.attachment
            preparingAttachmentID = candidate.attachment.id
            preparationWorker = (
                id,
                Task { [weak self] in
                    guard let self else { return }
                    defer {
                        self.activeAttachmentSlots[id] = nil
                        self.activeAttachmentTasks[id] = nil
                    }
                    await self.prepareAttachment(
                        candidate, workerID: id, store: store,
                        generation: current, transport: transport)
                    if self.preparationWorker?.id == id {
                        self.preparationWorker = nil
                        self.preparingAttachmentID = nil
                    }
                    self.wakeAttachmentWorkers()
                }
            )
            activeAttachmentTasks[id] = preparationWorker?.task
        }
        for candidate in work
        where !candidate.attachment.isUploaded
            && candidate.attachment.preparedPath != nil && candidate.attachment.error == nil
        {
            guard attachmentWorkers.count < 2 else { break }
            let slotID = candidate.attachment.id
            guard attachmentWorkers[slotID] == nil else { continue }
            let id = UUID()
            activeAttachmentSlots[id] = candidate.attachment
            attachmentWorkers[slotID] = (
                id,
                Task { [weak self] in
                    guard let self else { return }
                    defer {
                        self.activeAttachmentSlots[id] = nil
                        self.activeAttachmentTasks[id] = nil
                    }
                    await self.uploadAttachment(
                        candidate, store: store, generation: current,
                        transport: transport)
                    if self.attachmentWorkers[slotID]?.id == id {
                        self.attachmentWorkers[slotID] = nil
                        self.attachmentProgress[slotID] = nil
                    }
                    self.wakeWorkers()
                    self.updateSessionWorkState()
                }
            )
            activeAttachmentTasks[id] = attachmentWorkers[slotID]?.task
        }
        updateSessionWorkState()
    }

    private func prepareAttachment(
        _ work: AttachmentWork, workerID: UUID, store: ChahuaLocalStore,
        generation current: UInt64, transport: UInt64
    ) async {
        guard canDispatch(generation: current, transport: transport),
            currentAttachment(work) != nil
        else { return }
        do {
            let prepared = try await OutgoingImageProcessor(directory: store.directory)
                .prepare(work.attachment, compressionEnabled: work.compressionEnabled)
            guard canDispatch(generation: current, transport: transport),
                currentAttachment(work) != nil
            else { return }
            activeAttachmentSlots[workerID] = prepared
            try await persistAttachment(prepared, store: store, generation: current)
        } catch {
            await attachmentFailed(
                error, work: work, store: store,
                generation: current, transport: transport)
        }
    }

    private func uploadAttachment(
        _ work: AttachmentWork, store: ChahuaLocalStore,
        generation current: UInt64, transport: UInt64
    ) async {
        guard canDispatch(generation: current, transport: transport),
            currentAttachment(work) != nil
        else { return }
        var attachment = work.attachment
        do {
            let config = try await apiClient.attachmentConfig()
            guard canDispatch(generation: current, transport: transport),
                currentAttachment(work) != nil
            else { return }
            guard attachment.byteCount <= config.maxFileSizeBytes else {
                throw AttachmentWorkError.tooLarge(config.maxFileSizeBytes)
            }
            let allocation = try await apiClient.requestAttachmentUpload(
                fileName: attachment.fileName, contentType: attachment.mimeType,
                purpose: attachment.isFile ? .file : attachment.isAudio ? .voice : .media,
                size: attachment.byteCount, width: attachment.width, height: attachment.height,
                order: attachment.position)
            guard canDispatch(generation: current, transport: transport),
                currentAttachment(work) != nil
            else { return }
            let slotID = attachment.id
            try await OutgoingAttachmentUploader(directory: store.directory).upload(
                file: URL(fileURLWithPath: attachment.uploadPath), allocation: allocation
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current,
                        self.transportGeneration == transport,
                        self.currentAttachment(work) != nil
                    else { return }
                    let previous = self.attachmentProgress[slotID] ?? -1
                    if progress == 1 || abs(progress - previous) >= 0.01 {
                        self.attachmentProgress[slotID] = progress
                    }
                }
            }
            guard canDispatch(generation: current, transport: transport),
                currentAttachment(work) != nil
            else { return }
            attachment.attachmentID = allocation.attachmentId
            try await persistAttachment(attachment, store: store, generation: current)
        } catch {
            await attachmentFailed(
                error, work: work, store: store,
                generation: current, transport: transport)
        }
    }

    private func persistAttachment(
        _ attachment: LocalOutgoingAttachment, store: ChahuaLocalStore,
        generation current: UInt64
    ) async throws {
        do {
            try checkGeneration(current)
            // In-memory completion precedes the durable transfer barrier. A submit
            // can capture it even while its newly selected slot is not in a snapshot yet.
            replaceSessionSlot(attachment)
            if transientSlots[attachment.id] != nil { transientSlots[attachment.id] = attachment }
            let durableOwner = attachmentItems.first {
                !$0.isCancelled
                    && Self.localSlots($0).contains {
                        $0.id == attachment.id && $0.generation == attachment.generation
                    }
            }
            let editor = editSessions.values.first { session in
                session.attachments.contains {
                    if case .local(let slot) = $0 {
                        return slot.id == attachment.id && slot.generation == attachment.generation
                    }
                    return false
                }
            }
            if let clientID = durableOwner?.clientGeneratedID ?? editor?.clientGeneratedID {
                try await serialized(clientID) {
                    try self.checkGeneration(current)
                    guard
                        let owner = self.attachmentItems.first(where: {
                            !$0.isCancelled && $0.clientGeneratedID == clientID
                                && Self.localSlots($0).contains {
                                    $0.id == attachment.id && $0.generation == attachment.generation
                                }
                        })
                    else { return }
                    let updated = try await store.checkpointAttachment(
                        chatID: owner.chatID, threadID: owner.threadID, itemID: clientID,
                        attachment: attachment)
                    try self.checkGeneration(current)
                    self.publish(updated)
                }
            }
        } catch {
            storageFailed(error, operation: "checkpoint attachment", generation: current)
            throw error
        }
    }

    private func attachmentFailed(
        _ error: Error, work: AttachmentWork, store: ChahuaLocalStore,
        generation current: UInt64, transport: UInt64
    ) async {
        guard canDispatch(generation: current, transport: transport),
            currentAttachment(work) != nil, !(error is CancellationError)
        else { return }
        var failed = work.attachment
        failed.error = error.localizedDescription
        do {
            try await persistAttachment(failed, store: store, generation: current)
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
            case .tooLarge(let bytes):
                AppLanguage.localized(
                    "Attachment exceeds the server limit of \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
                )
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
                self.attachmentWorkers.isEmpty, self.attachmentMutationConversations.isEmpty,
                self.importingSessions.isEmpty
            else {
                self.scheduleFileCleanup()
                return
            }
            let retained = Set(
                (self.attachmentItems.filter { !$0.isCancelled }.flatMap {
                    Self.localSlots($0)
                } + self.activeCreates.values.flatMap(\.attachments)
                    + Array(self.activeAttachmentSlots.values)
                    + self.editSessions.values.flatMap { session in
                        session.attachments.compactMap {
                            if case .local(let slot) = $0 { slot } else { nil }
                        }
                    }).flatMap {
                        [$0.sourcePath, $0.previewPath] + ($0.preparedPath.map { [$0] } ?? [])
                    })
            // A grace period covers hosted pending-to-server preview handoff.
            // A fresh import has a unique path and a newer timestamp.
            try? await OutgoingFileCleanup.reclaim(
                directory: store.directory, retaining: retained,
                olderThan: Date().addingTimeInterval(-60))
        }
    }

    private func publish(_ snapshot: LocalConversationSnapshot, notify: Bool = true) {
        guard snapshots[snapshot.conversationKey].map({ snapshot.revision >= $0.revision }) ?? true
        else { return }
        snapshots[snapshot.conversationKey] = snapshot
        for session in Array(editSessions.values)
        where session.conversationKey == snapshot.conversationKey {
            guard
                let item = snapshot.outgoing.first(where: {
                    $0.clientGeneratedID == session.clientGeneratedID
                }), !item.isCancelled
            else {
                endPendingEdit(session)
                continue
            }
            for slot in Self.localSlots(item) { mergePublishedSlot(slot) }
            if let message = item.confirmedMessage {
                session.replaceUploadedSlots(serverAttachments: message.attachments)
            }
        }
        cancelUnreferencedAttachmentWorkers()
        if notify { events.send(.snapshot(snapshot)) }
        wakeAttachmentWorkers()
        wakeMutationWorkers()
        scheduleFileCleanup()
    }

    private func canDispatch(generation current: UInt64, transport: UInt64) -> Bool {
        generation == current && transportGeneration == transport && !Task.isCancelled
            && foregroundActive && transportReady && storageState == .ready && !authenticationFailed
    }

    private func checkpoint(_ operation: StorageOperation, generation current: UInt64) async throws
    {
        try await beforeStorageOperation?(operation)
        try checkGeneration(current)
    }

    private func checkGeneration(_ current: UInt64) throws {
        guard generation == current else { throw CancellationError() }
    }

    private func storageFailed(_ error: Error, operation: String, generation current: UInt64) {
        guard generation == current, !(error is CancellationError) else { return }
        if let error = error as? LocalStorageError {
            switch error {
            case .blankMessage, .staleDraft, .notTail, .dispatchAlreadyClaimed, .invalidAttachments,
                .unsupportedMessageType:
                logStorageError(error, operation: operation, generation: current, level: .default)
                return
            case .unsupportedSchema, .corruptRecord:
                break
            }
        }
        logStorageError(error, operation: operation, generation: current)
        storageState = .failed
    }

    private func logStorageError(
        _ error: Error, operation: String, generation current: UInt64, level: OSLogType = .error
    ) {
        guard generation == current, !(error is CancellationError) else { return }
        let error = error as NSError
        // SQLite and file errors can contain SQL values, message content, or paths.
        Self.logger.log(
            level: level,
            "Local persistence failed: operation=\(operation, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) details=\(error.description, privacy: .private)"
        )
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            Self.logger.log(
                level: level,
                "Local persistence underlying error: operation=\(operation, privacy: .public) domain=\(underlying.domain, privacy: .public) code=\(underlying.code, privacy: .public) details=\(underlying.description, privacy: .private)"
            )
        }
    }
}

/// Recorded M4A is upload-ready; the server canonicalizes voice to Ogg Opus.
/// Account-owned Outbox storage keeps retention, uploads and cleanup shared with media.
nonisolated private enum OutgoingVoiceFiles {
    enum ImportError: LocalizedError {
        case invalidAudio
        var errorDescription: String? {
            AppLanguage.localized("The voice recording is not a valid M4A file.")
        }
    }

    static func importVoice(from url: URL, directory: URL) async throws -> LocalOutgoingAttachment {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL,
                try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else {
                throw ImportError.invalidAudio
            }
            let root = try OutgoingImageFiles.root(directory)
            let manager = FileManager.default
            let outbox = root.appendingPathComponent("Outbox", isDirectory: true)
            try manager.createDirectory(
                at: outbox, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try OutgoingImageFiles.checkOutbox(outbox, root: root)
            let id = UUID().uuidString
            let staging = outbox.appendingPathComponent(".\(id).import", isDirectory: true)
            let installed = outbox.appendingPathComponent(id, isDirectory: true)
            try manager.createDirectory(
                at: staging, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: staging) }
            let copied = staging.appendingPathComponent("voice.m4a")
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            // The recorder supplies an M4A container, never an image/video composition.
            guard let header = try input.read(upToCount: 12), header.count == 12,
                header[4..<8].elementsEqual("ftyp".utf8),
                url.pathExtension.lowercased() == "m4a"
            else {
                throw ImportError.invalidAudio
            }
            try input.seek(toOffset: 0)
            guard
                manager.createFile(
                    atPath: copied.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: copied)
            defer { try? output.close() }
            var byteCount: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
                try output.write(contentsOf: data)
                byteCount += Int64(data.count)
            }
            try output.synchronize()
            try Task.checkCancellation()
            try manager.moveItem(at: staging, to: installed)
            let path = installed.appendingPathComponent("voice.m4a").path
            return LocalOutgoingAttachment(
                id: id, generation: UUID().uuidString, position: 0,
                sourcePath: path, preparedPath: path, previewPath: path,
                fileName: "voice.m4a", mimeType: "audio/mp4", width: 0, height: 0,
                byteCount: byteCount)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
