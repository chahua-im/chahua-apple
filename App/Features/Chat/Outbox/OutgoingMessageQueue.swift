import ChahuaAPI
import Combine
import Foundation
import OSLog

enum OutgoingStorageState: Equatable {
    case inactive, loading, ready, failed
}

enum OutgoingQueueEvent {
    case snapshot(LocalConversationSnapshot)
    case delivered(snapshot: LocalConversationSnapshot, message: MessageResponse, published: Bool)
    case purged(conversations: [ConversationKey])
}

enum IncomingOutgoingDisposition: Equatable {
    case unrelated, consumed, suppress
}

@MainActor
final class OutgoingMessageQueue: ObservableObject {
    enum StorageOperation: Equatable {
        case restore, saveDraft, enqueue, claim, fail, retry, acknowledge, edit, remove
        case purge
    }

    typealias UploadFile = @Sendable (
        _ directory: URL, _ file: URL, _ allocation: OutgoingUploadAllocation,
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Void

    enum QueueError: LocalizedError {
        case storageUnavailable, invalidAcknowledgement, invalidForwardSources, unavailableEditTarget
        case possibleDelivery

        var errorDescription: String? {
            switch self {
            case .storageUnavailable: AppLanguage.localized("Local message storage is unavailable.")
            case .invalidAcknowledgement: AppLanguage.localized("The server returned a different message.")
            case .invalidForwardSources: AppLanguage.localized("These messages can’t be forwarded.")
            case .unavailableEditTarget: AppLanguage.localized("This queued message is no longer editable.")
            case .possibleDelivery: AppLanguage.localized("The message may already have been delivered.")
            }
        }
    }

    private struct Worker {
        let id: UUID
        let itemID: String
        let task: Task<Void, Never>
    }

    private struct Receipt {
        let message: MessageResponse
        let published: Bool
    }

    private enum Completion {
        case delivery(Receipt)
        case failure(OutboxFailure, retryAfter: Date?)
        case unsent(priorFailure: OutboxFailure?, retry: PreflightRetry? = nil)
    }

    private struct PreflightRetry {
        let failure: OutboxFailure
        let retryAfter: Date?
    }

    private struct RetryWindow {
        let interval: Int
        let due: ContinuousClock.Instant
        let preflight: Bool
    }

    private struct Claim {
        let priorFailure: OutboxFailure?
    }

    private struct BackgroundGrant {
        let id: UUID
        let execution: OutboxBackgroundExecution
        let expiresAt: ContinuousClock.Instant?
        let expirationTimer: Task<Void, Never>?
    }

    private struct ScheduledRefresh {
        let id: UUID
        let completion: CheckedContinuation<Bool, Never>
        var draining = false
    }

    @Published private(set) var storageState: OutgoingStorageState = .inactive
    @Published private(set) var snapshots: [ConversationKey: LocalConversationSnapshot] = [:]
    @Published private(set) var attachmentProgress: [String: Double] = [:]
    let events = PassthroughSubject<OutgoingQueueEvent, Never>()

    var authorizeWrite: (@MainActor (String, String?) async throws -> Void)?
    var authorizeEnqueue: (@MainActor (ConversationKey) async throws -> Void)?
    var backgroundWorkDidChange: (() -> Void)?
    var onDiskFull: (() -> Void)?

    private static let logger = Logger(subsystem: "app.chahua.chat", category: "outbox")
    private let apiClient: any ChahuaAPIClient
    private let storage: AccountLocalStoreOwner
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private let beforeStorageOperation: (@MainActor @Sendable (StorageOperation) async throws -> Void)?
    private let uploadFile: UploadFile
    private let startBackgroundExecution: OutboxBackgroundExecution.Start
    private let runsWhileInactive: Bool
    private let clock = ContinuousClock()
    private let retryJitter: @MainActor () -> Double
    @Published private(set) var online = true
    private var uid: Int32?
    private var generation: UInt64 = 0
    private var foregroundActive: Bool
    private var signingOut = false
    private var authenticationFailed = false
    private var lifecycle: Task<Void, Never>?
    private var writes: Task<Void, Never>?
    private var restored = false
    private var workers: [ConversationKey: Worker] = [:]
    private var claimed = Set<String>()
    private var removing = Set<String>()
    private var manualRetries = Set<String>()
    private var completions: [String: Completion] = [:]
    private var pendingAudio: [MessageID: MessageResponse] = [:]
    private var editors: [String: PendingEditSession] = [:]
    private var savingEditors = Set<UUID>()
    private var importing = Set<ConversationKey>()
    private var fileLeases: [URL: Int] = [:]
    private var fileDrainWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var fileWorkers: [SlotIdentity: (directory: URL, work: AttachmentWork, task: Task<Void, Never>)] = [:]
    private var cleanup: Task<Void, Never>?
    private var retryWindows: [String: RetryWindow] = [:]
    private var retryTimer: (id: UUID, due: ContinuousClock.Instant, task: Task<Void, Never>)?
    private var recoveryWake: Task<Void, Never>?
    private var handedOff = Set<UUID>()
    private var activeClaims: [UUID: Claim] = [:]
    private var backgroundGrant: BackgroundGrant?
    private var attemptedGrant = false
    private var scheduledRefresh: ScheduledRefresh?

    init(
        apiClient: any ChahuaAPIClient, storage: AccountLocalStoreOwner,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void,
        beforeStorageOperation: (@MainActor @Sendable (StorageOperation) async throws -> Void)? = nil,
        runsWhileInactive: Bool = false, initiallyForeground: Bool = true,
        retryJitter: @escaping @MainActor () -> Double = { 0 },
        startBackgroundExecution: @escaping OutboxBackgroundExecution.Start = OutboxBackgroundExecution.start,
        uploadFile: @escaping UploadFile = { directory, file, allocation, progress in
            try await OutgoingAttachmentUploader(directory: directory)
                .upload(file: file, allocation: allocation, onProgress: progress)
        }
    ) {
        self.apiClient = apiClient
        self.storage = storage
        self.onInvalidToken = onInvalidToken
        self.beforeStorageOperation = beforeStorageOperation
        self.uploadFile = uploadFile
        self.startBackgroundExecution = startBackgroundExecution
        self.runsWhileInactive = runsWhileInactive
        self.retryJitter = retryJitter
        foregroundActive = initiallyForeground
    }

    func requestSession(uid: Int32?) {
        guard self.uid != uid else { return }
        let retiringCleanup = cleanup
        let retiringLifecycle = lifecycle
        suspendWorkers()
        completions.removeAll()
        pendingAudio.removeAll()
        snapshots.removeAll()
        authenticationFailed = false
        signingOut = false
        restored = false
        self.uid = uid
        let priorWrites = writes
        storage.fenceNextOpen(through: Task {
            await priorWrites?.value
            await retiringLifecycle?.value
            await retiringCleanup?.value
        })
        storage.setSession(uid: uid)
        storageState = uid == nil ? .inactive : .loading
        let current = generation
        lifecycle = Task { [weak self] in
            await priorWrites?.value
            await retiringLifecycle?.value
            await retiringCleanup?.value
            guard let self, self.generation == current, let uid else { return }
            await self.open(uid: uid, generation: current)
        }
        backgroundWorkDidChange?()
    }

    private func suspendWorkers() {
        compaction?.cancel()
        compaction = nil
        compacting = false
        generation &+= 1
        lifecycle?.cancel()
        endBackgroundGrant()
        endScheduledRefresh(success: false)
        activeClaims.removeAll()
        handedOff.removeAll()
        retryWindows.removeAll()
        retryTimer?.task.cancel()
        retryTimer = nil
        recoveryWake?.cancel()
        recoveryWake = nil
        for worker in workers.values { worker.task.cancel() }
        for worker in fileWorkers.values { worker.task.cancel() }
        for editor in editors.values { editor.invalidate() }
        cleanup?.cancel()
        cleanup = nil
        workers.removeAll()
        claimed.removeAll()
        removing.removeAll()
        manualRetries.removeAll()
        editors.removeAll()
        savingEditors.removeAll()
        importing.removeAll()
        attachmentProgress.removeAll()
    }

    var hasSignOutWork: Bool {
        storageState != .ready || !editors.isEmpty || snapshots.values.contains {
            !$0.outgoing.isEmpty || !$0.draft.text.isEmpty || $0.draft.replyToMessage != nil
                || !$0.draft.attachments.isEmpty || !$0.draft.linkPreviews.isEmpty
        }
    }

    func fenceForSignOut() {
        guard uid != nil, !signingOut else { return }
        signingOut = true
        let retiringCleanup = cleanup
        let retiringLifecycle = lifecycle
        suspendWorkers()
        let priorWrites = writes
        lifecycle = Task {
            await priorWrites?.value
            await retiringLifecycle?.value
            await retiringCleanup?.value
        }
        storageState = .inactive
        backgroundWorkDidChange?()
    }

    func resumeAfterUnregisterFailure() async {
        guard signingOut, let uid else { return }
        await lifecycle?.value
        guard signingOut, self.uid == uid else { return }
        signingOut = false
        restored = false
        storageState = .loading
        let current = generation
        lifecycle = Task { [weak self] in await self?.open(uid: uid, generation: current) }
        backgroundWorkDidChange?()
        await lifecycle?.value
    }

    func purgeForSignOut() async throws {
        guard signingOut, let uid else { throw CancellationError() }
        let current = generation
        await lifecycle?.value
        try checkGeneration(current)
        let store = try await storage.open(uid: uid)
        try checkGeneration(current)
        let directory = store.directory
        let uploads = fileWorkers.values.filter { $0.directory == directory }.map(\.task)
        for upload in uploads { await upload.value }
        if fileLeases[directory] != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                fileDrainWaiters[directory, default: []].append(continuation)
            }
        }
        try await checkpoint(.purge, generation: current)
        try await OutgoingFileCleanup.purge(directory: directory)
        try checkGeneration(current)
        try await store.purge()
        try checkGeneration(current)
        let keys = Array(snapshots.keys)
        snapshots.removeAll()
        pendingAudio.removeAll()
        completions.removeAll()
        events.send(.purged(conversations: keys))
    }

    func activate(uid: Int32) async {
        requestSession(uid: uid)
        await lifecycle?.value
    }

    func deactivate() async {
        requestSession(uid: nil)
        await lifecycle?.value
    }

    func requestForegroundActive(_ active: Bool) {
        guard foregroundActive != active else { return }
        foregroundActive = active
        if active {
            attemptedGrant = false
            endBackgroundGrant()
            wakeForRecovery()
        } else {
            if !runsWhileInactive {
                startBackgroundGrantIfNeeded()
                stopWorkWithoutExecution()
                cancelSpeculativeAttachments()
            }
            wakeWorkers()
        }
    }

    func setForegroundActive(_ active: Bool) async {
        requestForegroundActive(active)
    }

    func resynchronizePublications() {
        wakeForRecovery()
    }

    func setNetworkReachable(_ reachable: Bool) {
        guard reachable != online else { return }
        online = reachable
        if reachable {
            wakeForRecovery()
        } else {
            // Foreground creates can finish, but a finite run cannot wait for another path.
            for worker in fileWorkers.values { worker.task.cancel() }
            endBackgroundGrant()
            endScheduledRefresh(success: false)
            stopWorkWithoutExecution()
            wakeWorkers()
        }
    }

    private func wakeForRecovery() {
        backgroundWorkDidChange?()
        guard recoveryWake == nil else { return }
        let current = generation
        recoveryWake = Task { [weak self] in
            await Task.yield()
            guard let self, self.generation == current else { return }
            self.recoveryWake = nil
            self.wakeWorkers()
        }
    }

    func retryStorage() async {
        guard storageState == .failed, let uid else { return }
        storageState = .loading
        let current = generation
        lifecycle = Task { [weak self] in await self?.open(uid: uid, generation: current) }
        backgroundWorkDidChange?()
        await lifecycle?.value
    }

    private func open(uid: Int32, generation current: UInt64) async {
        do {
            let store = try await storage.open(uid: uid)
            try await ordered {
                try await self.checkpoint(.restore, generation: current)
                let snapshots = try await (self.restored ? store.load() : store.restore())
                try self.checkGeneration(current)
                self.restored = true
                for snapshot in snapshots {
                    if let head = snapshot.outgoing.first, let failure = head.failure,
                        self.retryWindows[head.clientGeneratedID] == nil
                    {
                        self.recordRetryWindow(id: head.clientGeneratedID, failure: failure)
                    }
                    self.publish(snapshot)
                }
                for snapshot in snapshots {
                    for item in snapshot.outgoing where self.completions[item.clientGeneratedID] != nil {
                        try await self.commitCompletion(
                            key: snapshot.conversationKey, itemID: item.clientGeneratedID,
                            store: store, generation: current)
                    }
                }
                self.storageState = .ready
            }
            wakeWorkers()
            scheduleFileCleanup()
        } catch {
            storageFailed(error, generation: current)
        }
    }

    // This barrier includes selecting inputs and publishing committed snapshots,
    // not transport waits. A different conversation can send while a request is held.
    private func ordered<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = writes
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        writes = Task { _ = await task.result }
        return try await task.value
    }

    private func checkpoint(_ operation: StorageOperation, generation current: UInt64) async throws {
        try checkGeneration(current)
        try await beforeStorageOperation?(operation)
        try checkGeneration(current)
    }

    private func checkGeneration(_ current: UInt64) throws {
        guard current == generation, !Task.isCancelled else { throw CancellationError() }
    }

    private func requireStore() throws -> ChahuaLocalStore {
        guard storageState == .ready, let store = storage.store else { throw QueueError.storageUnavailable }
        return store
    }

    private func storageFailed(_ error: Error, generation current: UInt64) {
        guard current == generation, !(error is CancellationError) else { return }
        if ChahuaLocalStore.isDiskFull(error) { onDiskFull?() }
        if error is QueueError { return }
        if let error = error as? LocalStorageError {
            switch error {
            case .corruptRecord: break
            default: return
            }
        }
        Self.logger.error("The outbox transaction failed: \(String(reflecting: type(of: error)), privacy: .public)")
        storageState = .failed
        wakeWorkers()
    }

    private func publish(_ snapshot: LocalConversationSnapshot, notify: Bool = true) {
        let key = snapshot.conversationKey
        guard snapshots[key].map({ snapshot.revision >= $0.revision }) ?? true else { return }
        snapshots[key] = snapshot
        for item in snapshot.outgoing {
            guard let session = editors[item.clientGeneratedID], session.isValid else { continue }
            let byID = Dictionary(uniqueKeysWithValues: item.attachments.map { ($0.id, $0) })
            session.replaceAttachments(session.attachments.map { selection in
                guard var checkpoint = byID[selection.id], checkpoint.generation == selection.generation
                else { return selection }
                checkpoint.position = selection.position
                return checkpoint
            })
        }
        for (id, worker) in fileWorkers
        where id.accountGeneration == generation && worker.work.key == key
            && !attachmentOwner(key, id).found
        {
            worker.task.cancel()
        }
        if notify { events.send(.snapshot(snapshot)) }
        scheduleFileCleanup()
    }

    func pendingMessages(chatID: String, threadID: String? = nil) -> [LocalOutgoingMessage] {
        snapshots[.init(chatID: chatID, threadID: threadID)]?.outgoing ?? []
    }

    func phase(of item: LocalOutgoingMessage) -> OutboxPhase {
        switch item.state {
        case .sending:
            return .sending
        case .failed:
            guard let failure = item.failure else { preconditionFailure("Failed row without failure") }
            let retry = shouldRetryAutomatically(item)
                ? retryDue(item, now: clock.now, date: Date()) : nil
            return .failed(failure, nextRetry: retry)
        case .pending:
            if !item.isReadyForDispatch {
                var progress: [String: Double] = [:]
                for slot in item.attachments {
                    progress[slot.id] = slot.isUploaded ? 1 : attachmentProgress[slot.id, default: 0]
                }
                return .preparing(progress: progress)
            }
            let head = snapshots[item.conversationKey]?.outgoing.first?.clientGeneratedID
            return .queued(blockedBy: head == item.clientGeneratedID ? nil : head)
        }
    }

    private func editSnapshot(
        _ operation: StorageOperation,
        _ transaction: @escaping @MainActor (ChahuaLocalStore) async throws -> LocalConversationSnapshot
    ) async throws {
        let current = generation
        try Task.checkCancellation()
        do {
            try await ordered {
                try await self.checkpoint(operation, generation: current)
                let snapshot = try await transaction(self.requireStore())
                try self.checkGeneration(current)
                self.publish(snapshot)
                self.wakeWorkers()
            }
        } catch {
            if operation != .saveDraft { storageFailed(error, generation: current) }
            throw error
        }
    }

    func saveDraft(
        chatID: String, threadID: String? = nil, text: String, editRevision: Int64, updatedAt: Date,
        replyToMessage: MessagePreview? = nil, linkPreviews: [LinkPreviewInput] = []
    ) async throws {
        try await editSnapshot(.saveDraft) {
            try await $0.saveDraft(
                chatID: chatID, threadID: threadID, text: text, editRevision: editRevision,
                updatedAt: updatedAt, replyToMessage: replyToMessage, linkPreviews: linkPreviews)
        }
    }

    private func requireEnqueuePermission(_ key: ConversationKey) async throws {
        let current = generation
        _ = try requireStore()
        if let authorizeEnqueue { try await authorizeEnqueue(key) }
        try checkGeneration(current)
    }

    func enqueueText(
        chatID: String, threadID: String? = nil, text: String, clearedDraftRevision: Int64,
        replyToMessage: MessagePreview? = nil, metadata: MessageMetadataInput? = nil
    ) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        try await requireEnqueuePermission(key)
        let id = UUID().uuidString
        let date = Date()
        try await editSnapshot(.enqueue) { store in
            guard !self.importing.contains(key) else { throw QueueError.storageUnavailable }
            return try await store.enqueueText(
                chatID: chatID, threadID: threadID, clientGeneratedID: id,
                text: text, enqueuedAt: date, clearedDraftRevision: clearedDraftRevision,
                replyToMessage: replyToMessage, metadata: metadata)
        }
    }

    func enqueueIndependentText(
        chatID: String, threadID: String? = nil, text: String,
        notificationDeadline: ContinuousClock.Instant? = nil
    ) async throws {
        try await requireEnqueuePermission(.init(chatID: chatID, threadID: threadID))
        let id = UUID().uuidString
        let date = Date()
        let current = generation
        try await editSnapshot(.enqueue) { store in
            let snapshot = try await store.enqueueIndependentText(
                chatID: chatID, threadID: threadID, clientGeneratedID: id, text: text,
                enqueuedAt: date)
            try self.checkGeneration(current)
            if let deadline = notificationDeadline, snapshot.outgoing.first?.clientGeneratedID == id {
                self.startBackgroundGrantIfNeeded(deadline: deadline, notificationHead: snapshot.outgoing.first)
            }
            return snapshot
        }
    }

    func enqueueSticker(
        chatID: String, threadID: String? = nil, sticker: MessageStickerResponse,
        replyToMessage: MessagePreview? = nil
    ) async throws {
        try await requireEnqueuePermission(.init(chatID: chatID, threadID: threadID))
        let id = UUID().uuidString
        let date = Date()
        try await editSnapshot(.enqueue) {
            try await $0.enqueueSticker(
                chatID: chatID, threadID: threadID, clientGeneratedID: id, sticker: sticker,
                enqueuedAt: date, replyToMessage: replyToMessage)
        }
    }

    func enqueueVoice(
        chatID: String, threadID: String? = nil, fileURL: URL, replyToMessage: MessagePreview? = nil
    ) async throws {
        let current = generation
        let store = try requireStore()
        let attachment = try await withFileLease(in: store.directory) {
            try await OutgoingVoiceFiles.importVoice(from: fileURL, directory: store.directory)
        }
        try checkGeneration(current)
        try await requireEnqueuePermission(.init(chatID: chatID, threadID: threadID))
        let id = UUID().uuidString
        let date = Date()
        try await editSnapshot(.enqueue) {
            try await $0.enqueueVoice(
                chatID: chatID, threadID: threadID, clientGeneratedID: id, attachment: attachment,
                enqueuedAt: date, replyToMessage: replyToMessage)
        }
    }

    var acknowledgedPendingAudioMessages: [MessageResponse] {
        pendingAudio.values.sorted { $0.id < $1.id }
    }

    func forwardPlaceholderReason(for source: MessageResponse, merging: Bool) -> String? {
        if source.messageType == .audio, pendingAudio[source.id]?.chatId == source.chatId {
            return "pendingAudio"
        }
        if merging, source.messageType == .forwarded,
            source.forwardedPreview?.containsForwardedMessages == true
        {
            return "nestedForward"
        }
        return nil
    }

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
        try await requireEnqueuePermission(.init(chatID: chatID, threadID: threadID))
        let request = LocalForwardRequest(
            sourceChatID: first.chatId,
            sources: sources.map { source in
                guard allowPlaceholders,
                    let reason = forwardPlaceholderReason(for: source, merging: sources.count > 1)
                else { return source }
                return ForwardPlaceholderProjection.replacing(source, reason: reason)
            },
            allowPlaceholders: allowPlaceholders)
        try await editSnapshot(.enqueue) {
            try await $0.enqueueForward(chatID: chatID, threadID: threadID, request: request)
        }
    }

    func retry(chatID: String, threadID: String? = nil, clientGeneratedID id: String) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let current = generation
        try await ordered {
            try await self.checkpoint(.retry, generation: current)
            let store = try self.requireStore()
            guard self.editors[id] == nil, let item = self.item(key, id), let failure = item.failure
            else { return }
            switch failure.stage {
            case .preparation:
                guard self.serverAllowsRetry(item) else { return }
                let snapshot = try await store.retryPreparation(key: key, itemID: id)
                try self.checkGeneration(current)
                self.publish(snapshot)
            case .create:
                self.manualRetries.insert(id)
            }
            self.wakeWorkers()
        }
    }

    static func requiresRemovalConfirmation(for failure: OutboxFailure?) -> Bool {
        guard let failure, failure.stage == .create else { return false }
        switch failure.reason {
        case .unknownOutcome, .network, .invalidReceipt: return true
        default: return false
        }
    }

    func removeOutgoing(
        chatID: String, threadID: String? = nil, itemID: String, allowPossibleDelivery: Bool = false
    ) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let current = generation
        try await editSnapshot(.remove) { store in
            guard self.editors[itemID] == nil, !self.claimed.contains(itemID),
                self.completions[itemID] == nil
            else { throw QueueError.unavailableEditTarget }
            if !allowPossibleDelivery,
                Self.requiresRemovalConfirmation(for: self.item(key, itemID)?.failure)
            {
                throw QueueError.possibleDelivery
            }
            self.removing.insert(itemID)
            defer { self.removing.remove(itemID) }
            let snapshot = try await store.removeOutgoing(key: key, itemID: itemID)
            try self.checkGeneration(current)
            self.manualRetries.remove(itemID)
            self.retryWindows[itemID] = nil
            return snapshot
        }
    }

    private var dispatchAuthorized = true
    private var compaction: Task<Void, Never>?
    private var compacting = false

    func compactHistoryWhenIdle() {
        guard compaction == nil, let store = storage.store else { return }
        let current = generation
        compaction = Task { [weak self] in
            while let self, self.generation == current, !Task.isCancelled {
                if self.workers.isEmpty && self.fileWorkers.isEmpty && self.importing.isEmpty
                    && self.fileLeases[store.directory] == nil
                {
                    self.compacting = true
                    try? await self.ordered { try await store.compactMessageStorage() }
                    guard self.generation == current else { return }
                    self.compacting = false
                    self.compaction = nil
                    self.wakeWorkers()
                    return
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func setDispatchAuthorized(_ authorized: Bool) {
        guard dispatchAuthorized != authorized else { return }
        dispatchAuthorized = authorized
        if authorized { wakeForRecovery() }
        else { wakeWorkers() }
    }

    private var allowsExecution: Bool {
        if foregroundActive || runsWhileInactive || scheduledRefresh?.draining == true { return true }
        guard let backgroundGrant else { return false }
        return backgroundGrant.expiresAt.map { clock.now < $0 } ?? true
    }

    private var canDispatch: Bool {
        dispatchAuthorized && storageState == .ready && online && !authenticationFailed && !compacting
    }

    private func isUnsuspended(_ head: LocalOutgoingMessage) -> Bool {
        editors[head.clientGeneratedID] == nil && !removing.contains(head.clientGeneratedID)
    }

    private func automaticDue(
        _ head: LocalOutgoingMessage, now: ContinuousClock.Instant, date: Date
    ) -> Date? {
        switch head.state {
        case .sending:
            return date
        case .failed:
            guard shouldRetryAutomatically(head) else { return nil }
        case .pending:
            if !head.isReadyForDispatch {
                return head.attachments.lazy.filter { !$0.isUploaded && $0.failure == nil }
                    .map { max(date, $0.retryNotBefore ?? date) }.min()
            }
        }
        return retryDue(head, now: now, date: date)
    }

    /// Scheduling is based on durable FIFO heads, not the current network or
    /// credential validation state: a later launch may have a usable opportunity.
    var automaticBackgroundWakeDate: Date? {
        guard uid != nil, !signingOut, !authenticationFailed else { return nil }
        let now = clock.now
        let date = Date()
        var earliest: Date?
        for snapshot in snapshots.values {
            guard let head = snapshot.outgoing.first, isUnsuspended(head),
                let due = automaticDue(head, now: now, date: date)
            else { continue }
            if due == date { return date }
            earliest = min(earliest ?? due, due)
        }
        return earliest
    }

    func drainScheduledRefresh() async -> Bool {
        guard scheduledRefresh == nil, !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { completion in
                guard !Task.isCancelled else {
                    completion.resume(returning: false)
                    return
                }
                scheduledRefresh = ScheduledRefresh(id: id, completion: completion)
                Task { [weak self, lifecycle = self.lifecycle] in
                    await lifecycle?.value
                    guard let self, self.scheduledRefresh?.id == id else { return }
                    if self.storageState == .failed { await self.retryStorage() }
                    guard self.scheduledRefresh?.id == id else { return }
                    guard self.storageState == .ready else {
                        self.endScheduledRefresh(success: self.storageState == .inactive && self.uid == nil)
                        return
                    }
                    self.scheduledRefresh?.draining = true
                    self.endBackgroundGrant()
                    if !self.foregroundActive { self.cancelSpeculativeAttachments() }
                    self.wakeWorkers()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.scheduledRefresh?.id == id else { return }
                self.endScheduledRefresh(success: false)
                self.stopWorkWithoutExecution()
                self.wakeWorkers()
            }
        }
    }

    private func endScheduledRefresh(success: Bool) {
        guard let refresh = scheduledRefresh else { return }
        scheduledRefresh = nil
        refresh.completion.resume(returning: success)
    }

    private func startBackgroundGrantIfNeeded(
        deadline: ContinuousClock.Instant? = nil, notificationHead: LocalOutgoingMessage? = nil
    ) {
        let now = clock.now
        let date = Date()
        guard !allowsExecution, !attemptedGrant, canDispatch,
            deadline.map({ $0 > now }) ?? true
        else { return }
        if let notificationHead {
            guard isUnsuspended(notificationHead),
                automaticDue(notificationHead, now: now, date: date) == date
            else { return }
        } else {
            guard !workers.isEmpty || snapshots.values.contains(where: {
                guard let head = $0.outgoing.first, isUnsuspended(head) else { return false }
                return automaticDue(head, now: now, date: date) == date
            }) else { return }
        }
        attemptedGrant = true
        let id = UUID()
        let expire: @MainActor () -> Void = { [weak self] in
            guard let self, self.backgroundGrant?.id == id else { return }
            self.endBackgroundGrant()
            self.stopWorkWithoutExecution()
            self.wakeWorkers()
        }
        guard let execution = startBackgroundExecution(expire) else { return }
        let timer = deadline.map { deadline in
            Task { [clock] in
                do { try await clock.sleep(until: deadline) } catch { return }
                expire()
            }
        }
        backgroundGrant = BackgroundGrant(id: id, execution: execution, expiresAt: deadline, expirationTimer: timer)
    }

    private func endBackgroundGrant() {
        guard let grant = backgroundGrant else { return }
        backgroundGrant = nil
        grant.expirationTimer?.cancel()
        grant.execution.finish()
    }

    private func stopWorkWithoutExecution() {
        guard !allowsExecution else { return }
        for worker in fileWorkers.values { worker.task.cancel() }

        let stopped = workers
        workers.removeAll()
        let current = generation
        for (key, worker) in stopped {
            worker.task.cancel()
            let handedOff = self.handedOff.remove(worker.id) != nil
            let claim = activeClaims.removeValue(forKey: worker.id)
            guard let claim, completions[worker.itemID] == nil else { continue }
            if handedOff {
                let failure = OutboxFailure(stage: .create, reason: .unknownOutcome, retry: .automatic)
                completions[worker.itemID] = .failure(failure, retryAfter: nil)
            } else {
                completions[worker.itemID] = .unsent(priorFailure: claim.priorFailure)
            }
            Task { [weak self] in
                await self?.finish(key: key, itemID: worker.itemID, generation: current)
            }
        }
    }

    private func cancelSpeculativeAttachments() {
        for (id, worker) in fileWorkers where id.accountGeneration == generation {
            if !worker.work.isForSubmittedHead(in: snapshots, matching: id) { worker.task.cancel() }
        }
    }

    private func shouldRetryAutomatically(_ item: LocalOutgoingMessage) -> Bool {
        guard let failure = item.failure else { return false }
        if failure.retry == .automatic { return true }
        // A retryable preflight can release a manual retry claim back to its
        // prior failure. Only a preflight can leave a deadline on that row.
        return failure.stage == .create
            && (retryWindows[item.clientGeneratedID]?.preflight == true || item.retryNotBefore != nil)
    }

    private func automaticRetryDue(_ item: LocalOutgoingMessage) -> Bool {
        guard shouldRetryAutomatically(item) else { return false }
        let date = Date()
        return retryDue(item, now: clock.now, date: date) <= date
    }

    private func recordRetryWindow(
        id: String, failure: OutboxFailure, preflight: Bool = false
    ) {
        guard failure.retry == .automatic else {
            retryWindows[id] = nil
            return
        }
        let interval = retryWindows[id].map { min(60, $0.interval * 2) } ?? 1
        let delay = min(60, Double(interval) * (1 + min(0.2, max(0, retryJitter()))))
        retryWindows[id] = .init(
            interval: interval, due: clock.now.advanced(by: .seconds(delay)), preflight: preflight)
    }

    private func serverRetryDate(_ item: LocalOutgoingMessage) -> Date? {
        guard item.failure?.stage == .preparation,
            let attachmentDate = item.attachments.lazy.compactMap(\.retryNotBefore).max()
        else { return item.retryNotBefore }
        return max(attachmentDate, item.retryNotBefore ?? attachmentDate)
    }

    private func retryDue(
        _ item: LocalOutgoingMessage, now: ContinuousClock.Instant, date: Date
    ) -> Date {
        let window = retryWindows[item.clientGeneratedID]
        let localDue = (item.state == .failed || window?.preflight == true) ? window?.due : nil
        let localDelay = localDue.map { Self.seconds(now.duration(to: $0)) } ?? 0
        return max(date.addingTimeInterval(max(0, localDelay)), serverRetryDate(item) ?? date)
    }

    private func scheduleRetries() {
        let due = nextRetryDeadline()
        guard retryTimer?.due != due else { return }
        retryTimer?.task.cancel()
        retryTimer = nil
        guard let due else { return }
        let id = UUID()
        retryTimer = (id, due, Task { [weak self, clock] in
            do { try await clock.sleep(until: due) } catch { return }
            guard let self, self.retryTimer?.id == id else { return }
            self.retryTimer = nil
            self.wakeWorkers()
        })
    }

    private func nextRetryDeadline() -> ContinuousClock.Instant? {
        guard canDispatch, foregroundActive || runsWhileInactive else { return nil }
        var next: Date?
        let now = clock.now
        let date = Date()
        for (key, snapshot) in snapshots {
            if let head = snapshot.outgoing.first, head.state != .sending, workers[key] == nil,
                isUnsuspended(head), completions[head.clientGeneratedID] == nil
            {
                let due = manualRetries.contains(head.clientGeneratedID)
                    ? serverRetryDate(head) : automaticDue(head, now: now, date: date)
                consider(due)
            }
            // Foreground preparation can also prefetch non-head submitted slots.
            // A different slot already eligible for work must not hide this wake.
            let outgoing = foregroundActive ? snapshot.outgoing[...] : snapshot.outgoing.prefix(1)
            for item in outgoing where item.state == .pending && isUnsuspended(item) {
                for slot in item.attachments where !slot.isUploaded && slot.failure == nil {
                    consider(slot.retryNotBefore)
                }
            }
        }
        return next.map { now.advanced(by: .seconds($0.timeIntervalSince(date))) }

        func consider(_ due: Date?) {
            guard let due, due > date else { return }
            next = min(next ?? due, due)
        }
    }

    private func wakePreparationRetry(_ head: LocalOutgoingMessage) {
        let key = head.conversationKey
        let id = head.clientGeneratedID
        let workerID = UUID()
        let current = generation
        workers[key] = Worker(id: workerID, itemID: id, task: Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ordered {
                    try await self.checkpoint(.retry, generation: current)
                    guard self.canDispatch, self.allowsExecution, self.workers[key]?.id == workerID,
                        self.editors[id] == nil, let item = self.item(key, id),
                        item.failure?.stage == .preparation, self.automaticRetryDue(item)
                    else { return }
                    let store = try self.requireStore()
                    let snapshot = try await store.retryPreparation(key: key, itemID: id)
                    try self.checkGeneration(current)
                    self.publish(snapshot)
                }
            } catch {
                self.storageFailed(error, generation: current)
            }
            guard self.workers[key]?.id == workerID else { return }
            self.workers[key] = nil
            self.wakeWorkers()
        })
    }

    private static func retryAfter(from error: Error) -> Date? {
        if case OutgoingAttachmentUploadError.httpStatus(_, let retryAfter) = error {
            return retryAfter
        }
        return (error as? APIError)?.retryAfter
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func item(_ key: ConversationKey, _ id: String) -> LocalOutgoingMessage? {
        snapshots[key]?.outgoing.first { $0.clientGeneratedID == id }
    }

    private func wakeWorkers() {
        if canDispatch, allowsExecution {
            for key in snapshots.keys { wakeWorker(key) }
            wakeAttachmentWorkers()
        }
        if backgroundGrant != nil || scheduledRefresh?.draining == true {
            let busy = canDispatch && allowsExecution && (
                !workers.isEmpty || !completions.isEmpty
                    || fileWorkers.contains { id, worker in
                        id.accountGeneration == generation && !worker.task.isCancelled
                            && worker.work.isForSubmittedHead(in: snapshots, matching: id)
                    }
            )
            if !busy {
                endBackgroundGrant()
                if scheduledRefresh?.draining == true {
                    let now = clock.now
                    let date = Date()
                    let deferred = snapshots.values.contains {
                        $0.outgoing.first.flatMap { automaticDue($0, now: now, date: date) } != nil
                    }
                    endScheduledRefresh(success: storageState == .ready && !deferred)
                }
                stopWorkWithoutExecution()
            }
        }
        scheduleRetries()
        backgroundWorkDidChange?()
    }

    private func wakeWorker(_ key: ConversationKey) {
        guard canDispatch, allowsExecution, workers[key] == nil, let head = snapshots[key]?.outgoing.first
        else { return }
        if head.failure?.stage == .preparation {
            let id = head.clientGeneratedID
            if editors[id] == nil, !removing.contains(id), completions[id] == nil, automaticRetryDue(head) {
                wakePreparationRetry(head)
            }
            return
        }
        guard eligible(head) else { return }
        let workerID = UUID()
        let current = generation
        let id = head.clientGeneratedID
        workers[key] = Worker(id: workerID, itemID: id, task: Task { [weak self] in
            guard let self else { return }
            await self.sendHead(key: key, itemID: id, workerID: workerID, generation: current)
            self.handedOff.remove(workerID)
            self.activeClaims[workerID] = nil
            guard self.workers[key]?.id == workerID else { return }
            self.workers[key] = nil
            self.wakeWorkers()
        })
    }

    private func serverAllowsRetry(_ item: LocalOutgoingMessage) -> Bool {
        guard let date = serverRetryDate(item) else { return true }
        return date <= Date()
    }
    private func eligible(_ head: LocalOutgoingMessage) -> Bool {
        let id = head.clientGeneratedID
        guard head.isReadyForDispatch, editors[id] == nil, !claimed.contains(id),
            !removing.contains(id), completions[id] == nil
        else { return false }
        guard head.state == .pending || head.failure?.stage == .create else { return false }
        if manualRetries.contains(id) { return serverAllowsRetry(head) }
        if head.state == .pending, head.retryNotBefore == nil, retryWindows[id]?.preflight != true {
            return true
        }
        let date = Date()
        return (head.state == .pending || shouldRetryAutomatically(head))
            && retryDue(head, now: clock.now, date: date) <= date
    }

    private func sendHead(key: ConversationKey, itemID id: String, workerID: UUID, generation current: UInt64)
        async
    {
        let claimedHead: (message: LocalOutgoingMessage, priorFailure: OutboxFailure?)
        do {
            let message = try await ordered {
                try await self.checkpoint(.claim, generation: current)
                guard self.canDispatch, self.allowsExecution,
                    self.workers[key]?.id == workerID, let head = self.snapshots[key]?.outgoing.first,
                    head.clientGeneratedID == id, self.eligible(head)
                else { return Optional<(LocalOutgoingMessage, OutboxFailure?)>.none }
                let store = try self.requireStore()
                self.claimed.insert(id)
                defer { self.claimed.remove(id) }
                // Record the prior state before the transaction suspends. Expiration
                // can then release this exact claim in the same write stream.
                self.activeClaims[workerID] = Claim(priorFailure: head.failure)
                let claim = try await store.claimNext(
                    chatID: key.chatID, threadID: key.threadID, expectedID: id,
                    retryCreate: head.failure?.stage == .create)
                try self.checkGeneration(current)
                self.manualRetries.remove(id)
                self.publish(claim.snapshot)
                return claim.message.map { ($0, head.failure) }
            }
            guard let message, workers[key]?.id == workerID else { return }
            claimedHead = message
        } catch {
            storageFailed(error, generation: current)
            return
        }
        let pending = claimedHead.message
        do {
            try await authorizeWrite?(key.chatID, key.threadID)
            try checkGeneration(current)
            guard workers[key]?.id == workerID else { return }
            guard canDispatch, allowsExecution else {
                completions[id] = .unsent(priorFailure: claimedHead.priorFailure)
                await finish(key: key, itemID: id, generation: current)
                return
            }
            handedOff.insert(workerID)
            let message = try await create(pending)
            try checkGeneration(current)
            guard workers[key]?.id == workerID else { return }
            guard matches(message, pending) else { throw QueueError.invalidAcknowledgement }
            _ = await acceptAcknowledgement(
                message, published: Self.isPublishedCreateResponse(message, for: pending))
        } catch {
            guard current == generation, workers[key]?.id == workerID, item(key, id) != nil,
                completions[id] == nil
            else { return }
            let failure = Self.failure(error, stage: .create)
            if !handedOff.contains(workerID), failure.retry == .automatic {
                let retry = PreflightRetry(failure: failure, retryAfter: Self.retryAfter(from: error))
                completions[id] = .unsent(priorFailure: claimedHead.priorFailure, retry: retry)
                await finish(key: key, itemID: id, generation: current)
                return
            }
            if let existing = (error as? APIError)?.conflictingExistingMessage, matches(existing, pending) {
                _ = await acceptAcknowledgement(
                    existing, published: Self.isPublishedCreateResponse(existing, for: pending))
                return
            }
            completions[id] = .failure(failure, retryAfter: Self.retryAfter(from: error))
            await finish(key: key, itemID: id, generation: current)
            guard current == generation, failure.reason == .authentication,
                item(key, id) != nil
            else { return }
            authenticationFailed = true
            await onInvalidToken()
        }
    }

    private static func isPublishedCreateResponse(_ message: MessageResponse, for item: LocalOutgoingMessage) -> Bool {
        message.isDeleted || item.forwardRequest != nil || item.messageType != .audio
            || message.attachments.contains { $0.kind == "audio/ogg" }
    }

    private func create(_ pending: LocalOutgoingMessage) async throws -> MessageResponse {
        if let forward = pending.forwardRequest {
            let ids = forward.messageIDs
            if ids.count == 1 {
                return try await apiClient.forwardMessage(
                    chatID: pending.chatID, messageID: ids[0],
                    body: .init(
                        sourceChatId: forward.sourceChatID, clientGeneratedId: pending.clientGeneratedID,
                        threadId: pending.threadID, allowPlaceholders: forward.allowPlaceholders))
            }
            return try await apiClient.forwardMessages(
                chatID: pending.chatID,
                body: .init(
                    sourceChatId: forward.sourceChatID, messageIds: ids,
                    clientGeneratedId: pending.clientGeneratedID, threadId: pending.threadID,
                    allowPlaceholders: forward.allowPlaceholders))
        }
        if let threadID = pending.threadID {
            return try await apiClient.sendThreadMessage(
                chatID: pending.chatID, threadID: threadID, body: pending.body)
        }
        return try await apiClient.sendMessage(chatID: pending.chatID, body: pending.body)
    }

    private func matches(_ message: MessageResponse, _ item: LocalOutgoingMessage) -> Bool {
        message.clientGeneratedId == item.clientGeneratedID && message.sender.uid == item.senderID
            && message.sender.uid == uid && message.chatId == item.chatID && message.replyRootId == item.threadID
    }

    func acceptPublishedForwardSource(_ message: MessageResponse) {
        guard message.sender.uid == uid else { return }
        if let processing = pendingAudio[message.id],
            processing.clientGeneratedId == message.clientGeneratedId,
            processing.chatId == message.chatId, processing.replyRootId == message.replyRootId
        {
            pendingAudio[message.id] = nil
            return
        }
        let current = generation
        Task { [weak self] in
            guard let self, self.generation == current else { return }
            _ = await self.acceptAcknowledgement(message)
        }
    }

    func acceptDeletion(_ message: MessageResponse) async -> IncomingOutgoingDisposition {
        await acceptAcknowledgement(message.redactedForDeletion())
    }

    func acceptAcknowledgement(
        _ message: MessageResponse, published: Bool = true
    ) async -> IncomingOutgoingDisposition {
        let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
        let id = message.clientGeneratedId
        let published = published || message.isDeleted
        guard !signingOut, message.sender.uid == uid, !id.isEmpty else { return .unrelated }
        // Read snapshots inside the ordered barrier if a claim is committing.
        let current = generation
        do {
            return try await ordered {
                try self.checkGeneration(current)
                if published, let processing = self.pendingAudio[message.id],
                    processing.clientGeneratedId == id, processing.chatId == key.chatID,
                    processing.replyRootId == key.threadID
                {
                    self.pendingAudio[message.id] = nil
                    return .unrelated
                }
                guard let pending = self.item(key, id), self.matches(message, pending),
                    pending.state == .sending || pending.failure?.stage == .create,
                    let store = self.storage.store
                else { return .unrelated }
                let redacted = message.isDeleted ? message.redactedForDeletion() : message
                // Recovery may still hold a stronger receipt when a late HTTP result arrives.
                if case .delivery(let previous) = self.completions[id],
                    previous.message.isDeleted || (previous.published && !message.isDeleted)
                {
                    return .suppress
                }
                self.completions[id] = .delivery(Receipt(message: redacted, published: published))
                try await self.commitCompletion(key: key, itemID: id, store: store, generation: current)
                return .consumed
            }
        } catch {
            storageFailed(error, generation: current)
            return .suppress
        }
    }

    private func finish(key: ConversationKey, itemID: String, generation current: UInt64) async {
        do {
            try await ordered {
                try self.checkGeneration(current)
                guard let store = self.storage.store else { return }
                try await self.commitCompletion(key: key, itemID: itemID, store: store, generation: current)
            }
        } catch {
            storageFailed(error, generation: current)
        }
    }

    private func commitCompletion(
        key: ConversationKey, itemID id: String, store: ChahuaLocalStore, generation current: UInt64
    ) async throws {
        switch completions[id] {
        case .delivery(let receipt):
            try await checkpoint(.acknowledge, generation: current)
            let snapshot = try await store.settleCreate(receipt.message, published: receipt.published)
            try checkGeneration(current)
            completions[id] = nil
            guard let snapshot else { return }
            manualRetries.remove(id)
            retryWindows[id] = nil
            if !receipt.published && !receipt.message.isDeleted {
                pendingAudio[receipt.message.id] = receipt.message
            }
            if let worker = workers[key], worker.itemID == id {
                handedOff.remove(worker.id)
                activeClaims[worker.id] = nil
                workers[key] = nil
                worker.task.cancel()
            }
            publish(snapshot, notify: false)
            events.send(.delivered(snapshot: snapshot, message: receipt.message, published: receipt.published))
        case .failure(let failure, let retryAfter):
            try await checkpoint(.fail, generation: current)
            let snapshot = try await store.fail(key: key, itemID: id, failure: failure, retryNotBefore: retryAfter)
            try checkGeneration(current)
            completions[id] = nil
            if failure.reason == .authentication { authenticationFailed = true }
            recordRetryWindow(id: id, failure: failure)
            publish(snapshot)
        case .unsent(let priorFailure, let retry):
            let snapshot = try await store.releaseUnsentClaim(
                key: key, itemID: id, priorFailure: priorFailure, retryNotBefore: retry?.retryAfter)
            try checkGeneration(current)
            completions[id] = nil
            if let retry {
                recordRetryWindow(id: id, failure: retry.failure, preflight: true)
            }
            publish(snapshot)
        case nil:
            return
        }
        wakeWorkers()
    }

    private static func failure(_ error: Error, stage: OutboxFailure.Stage) -> OutboxFailure {
        if error is CancellationError {
            return .init(stage: stage, reason: .unknownOutcome, retry: .automatic)
        }
        if let mode = (error as? APIError)?.speakingRestriction
            ?? (error as? SpeakingWriteError)?.speakingRestriction
        {
            return .init(stage: stage, reason: .speakingRestricted(mode), retry: .manual)
        }
        if let api = error as? APIError {
            switch api {
            case .invalidToken, .unauthorized, .http(status: 401, body: _):
                return .init(stage: stage, reason: .authentication, retry: .manual)
            case .http(status: 409, body: _):
                return .init(stage: stage, reason: .conflict, retry: .manual)
            case .transport, .unavailable, .retryableHTTP:
                return .init(stage: stage, reason: .network, retry: .automatic)
            case .http(let status, _) where status == 408 || status == 429 || (500...599).contains(status):
                return .init(stage: stage, reason: .network, retry: .automatic)
            default: break
            }
        }
        if error is URLError {
            return .init(stage: stage, reason: .network, retry: .automatic)
        }
        if case OutgoingAttachmentUploadError.httpStatus(let status, _) = error,
            status == 408 || status == 429 || (500...599).contains(status)
        {
            return .init(stage: stage, reason: .network, retry: .automatic)
        }
        if case QueueError.invalidAcknowledgement = error {
            return .init(stage: stage, reason: .invalidReceipt, retry: .manual)
        }
        if let size = error as? AttachmentSizeError {
            return .init(stage: stage, reason: .tooLarge(size.limit), retry: .manual)
        }
        return .init(stage: stage, reason: stage == .create ? .rejected : .attachment, retry: .manual)
    }

    func beginPendingEdit(_ pending: PendingOutgoingMessage) throws -> PendingEditSession {
        let key = ConversationKey(chatID: pending.chatID, threadID: pending.threadID)
        let id = pending.clientGeneratedID
        guard storageState == .ready, pending.senderID == uid, let item = item(key, id),
            item.isEditable, editors[id] == nil, !claimed.contains(id),
            !removing.contains(id), completions[id] == nil
        else { throw QueueError.unavailableEditTarget }
        let session = PendingEditSession(
            conversationKey: key, clientGeneratedID: id, accountGeneration: generation,
            initialText: item.text, initialAttachments: item.attachments, initialMetadata: item.metadata,
            initialReplyToMessage: item.replyToMessage, compressionEnabled: item.compressionEnabled)
        editors[id] = session
        backgroundWorkDidChange?()
        return session
    }

    func submitPendingEdit(
        _ session: PendingEditSession, text: String, metadata: MessageMetadataInput?
    ) async throws {
        try validate(session)
        guard session.hasChanges(text: text, metadata: metadata),
            !session.isUploading, savingEditors.insert(session.id).inserted
        else {
            throw QueueError.unavailableEditTarget
        }
        defer { savingEditors.remove(session.id) }
        try await editSnapshot(.edit) { store in
            try self.validate(session)
            return try await store.editOutgoing(
                key: session.conversationKey, itemID: session.clientGeneratedID, text: text,
                replyToMessage: session.replyToMessage, attachments: session.attachments,
                compressionEnabled: session.compressionEnabled, metadata: metadata)
        }
        endPendingEdit(session)
    }

    func endPendingEdit(_ session: PendingEditSession) {
        guard editors[session.clientGeneratedID]?.id == session.id else { return }
        editors[session.clientGeneratedID] = nil
        session.invalidate()
        scheduleFileCleanup()
        wakeWorkers()
    }

    private func validate(_ session: PendingEditSession) throws {
        guard session.isValid, session.accountGeneration == generation,
            editors[session.clientGeneratedID]?.id == session.id
        else { throw QueueError.unavailableEditTarget }
    }

    func importEditAttachments(urls: [URL], session: PendingEditSession, asFiles: Bool) async throws {
        try validate(session)
        guard !session.isUploading, !savingEditors.contains(session.id),
            session.attachments.count + urls.count <= 20
        else { throw LocalStorageError.invalidAttachments }
        let directory = try requireStore().directory
        session.setUploading(true)
        defer { session.setUploading(false) }
        for url in urls {
            var slot = try await importAttachment(url, directory: directory, asFile: asFiles)
            try validate(session)
            slot.position = session.attachments.count
            session.replaceAttachments(session.attachments + [slot])
        }
    }

    func removeEditAttachment(id: String, session: PendingEditSession) {
        guard (try? validate(session)) != nil, !savingEditors.contains(session.id) else { return }
        session.replaceAttachments(Self.positioned(session.attachments.filter { $0.id != id }))
    }

    func reorderEditAttachments(ids: [String], session: PendingEditSession) throws {
        try validate(session)
        guard !savingEditors.contains(session.id) else { throw QueueError.unavailableEditTarget }
        session.replaceAttachments(try Self.reordered(session.attachments, ids: ids))
    }

    func retryEditAttachment(id: String, session: PendingEditSession) {
        guard (try? validate(session)) != nil, !savingEditors.contains(session.id) else { return }
        session.replaceAttachments(session.attachments.map { slot in
            guard slot.id == id, slot.retryNotBefore.map({ $0 <= Date() }) ?? true else { return slot }
            var updated = slot
            updated.generation = UUID().uuidString
            updated.failure = nil
            updated.retryNotBefore = nil
            return updated
        })
    }

    func setEditCompression(_ enabled: Bool, session: PendingEditSession) throws {
        try validate(session)
        guard !savingEditors.contains(session.id) else { throw QueueError.unavailableEditTarget }
        guard session.compressionEnabled != enabled else { return }
        session.setCompressionEnabled(enabled)
        session.replaceAttachments(Self.resetCompression(session.attachments))
    }

    func draftAttachments(chatID: String, threadID: String? = nil) -> [LocalOutgoingAttachment] {
        snapshots[.init(chatID: chatID, threadID: threadID)]?.draft.attachments ?? []
    }

    func compressionEnabled(chatID: String, threadID: String? = nil) -> Bool {
        snapshots[.init(chatID: chatID, threadID: threadID)]?.draft.compressionEnabled ?? true
    }

    func importImages(urls: [URL], chatID: String, threadID: String? = nil) async throws {
        try await importAttachments(urls: urls, key: .init(chatID: chatID, threadID: threadID), asFiles: false)
    }

    func importFiles(urls: [URL], chatID: String, threadID: String? = nil) async throws {
        try await importAttachments(urls: urls, key: .init(chatID: chatID, threadID: threadID), asFiles: true)
    }

    private func importAttachments(urls: [URL], key: ConversationKey, asFiles: Bool) async throws {
        let directory = try requireStore().directory
        guard (snapshots[key]?.draft.attachments.count ?? 0) + urls.count <= 20,
            importing.insert(key).inserted
        else { throw LocalStorageError.invalidAttachments }
        let current = generation
        defer { if current == generation { importing.remove(key) } }
        for url in urls {
            let slot = try await importAttachment(url, directory: directory, asFile: asFiles)
            try checkGeneration(current)
            try await changeDraft(key, duringImport: true) { $0 + [slot] }
        }
    }

    private func importAttachment(_ url: URL, directory: URL, asFile: Bool) async throws
        -> LocalOutgoingAttachment
    {
        try await withFileLease(in: directory) {
            if asFile {
                return try await OutgoingFileImporter(directory: directory).importFile(from: url, position: 0)
            }
            return try await OutgoingImageProcessor(directory: directory)
                .importImage(from: url, directory: directory, position: 0)
        }
    }

    func discardDraftAttachments(chatID: String, threadID: String? = nil) async throws {
        try await changeDraft(.init(chatID: chatID, threadID: threadID)) { _ in [] }
    }

    func removeAttachment(id: String, chatID: String, threadID: String? = nil) async throws {
        try await changeDraft(.init(chatID: chatID, threadID: threadID)) { $0.filter { $0.id != id } }
    }

    func reorderAttachments(ids: [String], chatID: String, threadID: String? = nil) async throws {
        try await changeDraft(.init(chatID: chatID, threadID: threadID)) {
            try Self.reordered($0, ids: ids)
        }
    }

    func setCompressionEnabled(_ enabled: Bool, chatID: String, threadID: String? = nil) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        try await changeDraft(key, compression: enabled) { slots in
            guard self.snapshots[key]?.draft.compressionEnabled != enabled else { return slots }
            return Self.resetCompression(slots)
        }
    }

    func retryAttachment(id: String, chatID: String, threadID: String? = nil) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        try await changeDraft(key) { slots in
            slots.map {
                guard $0.id == id, $0.failure != nil, $0.retryNotBefore.map({ $0 <= Date() }) ?? true
                else { return $0 }
                var slot = $0
                slot.generation = UUID().uuidString
                slot.failure = nil
                slot.retryNotBefore = nil
                return slot
            }
        }
    }

    private func changeDraft(
        _ key: ConversationKey, compression: Bool? = nil, duringImport: Bool = false,
        transform: @escaping @MainActor ([LocalOutgoingAttachment]) throws -> [LocalOutgoingAttachment]
    ) async throws {
        try await editSnapshot(.saveDraft) { store in
            guard duringImport || !self.importing.contains(key) else { throw QueueError.storageUnavailable }
            let draft = self.snapshots[key]?.draft
            return try await store.setDraftAttachments(
                key: key, attachments: Self.positioned(try transform(draft?.attachments ?? [])),
                compressionEnabled: compression ?? draft?.compressionEnabled ?? true)
        }
    }

    private static func positioned(_ slots: [LocalOutgoingAttachment]) -> [LocalOutgoingAttachment] {
        slots.enumerated().map { position, value in
            var slot = value
            slot.position = position
            return slot
        }
    }

    private static func reordered(_ slots: [LocalOutgoingAttachment], ids: [String]) throws
        -> [LocalOutgoingAttachment]
    {
        guard ids.count == slots.count, Set(ids).count == ids.count,
            Set(ids) == Set(slots.map(\.id))
        else { throw LocalStorageError.invalidAttachments }
        let byID = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        return positioned(ids.compactMap { byID[$0] })
    }

    private static func resetCompression(_ slots: [LocalOutgoingAttachment]) -> [LocalOutgoingAttachment] {
        slots.map {
            guard !$0.isFile, !$0.isAudio else { return $0 }
            var slot = $0
            slot.generation = UUID().uuidString
            slot.preparedPath = nil
            slot.attachmentID = nil
            slot.failure = nil
            slot.retryNotBefore = nil
            return slot
        }
    }

    private struct SlotIdentity: Hashable {
        let id: String
        let generation: String
        let accountGeneration: UInt64
        init(_ slot: LocalOutgoingAttachment, accountGeneration: UInt64) {
            self.accountGeneration = accountGeneration
            id = slot.id
            generation = slot.generation
        }
        func matches(_ slot: LocalOutgoingAttachment) -> Bool {
            id == slot.id && generation == slot.generation
        }
    }

    private struct AttachmentWork {
        let key: ConversationKey
        let slot: LocalOutgoingAttachment
        let compression: Bool
        var needsPreparation: Bool { !slot.isAudio && !slot.isFile && slot.preparedPath == nil }

        func isForSubmittedHead(
            in snapshots: [ConversationKey: LocalConversationSnapshot], matching id: SlotIdentity
        ) -> Bool {
            snapshots[key]?.outgoing.first?.attachments.contains(where: id.matches) == true
        }
    }

    private func wakeAttachmentWorkers() {
        guard canDispatch, allowsExecution, let store = storage.store else { return }
        let current = generation
        let date = Date()
        var prepares = 0
        var uploads = 0
        for (id, worker) in fileWorkers where id.accountGeneration == current {
            if worker.work.needsPreparation { prepares += 1 } else { uploads += 1 }
        }
        guard prepares < 1 || uploads < 2 else { return }
        for (key, snapshot) in snapshots {
            if foregroundActive {
                for item in snapshot.outgoing
                where item.state == .pending && editors[item.clientGeneratedID] == nil {
                    for slot in item.attachments { start(slot, key: key, compression: item.compressionEnabled) }
                }
                for slot in snapshot.draft.attachments {
                    start(slot, key: key, compression: snapshot.draft.compressionEnabled)
                }
            } else if let head = snapshot.outgoing.first, head.state == .pending,
                editors[head.clientGeneratedID] == nil, !removing.contains(head.clientGeneratedID),
                completions[head.clientGeneratedID] == nil
            {
                for slot in head.attachments { start(slot, key: key, compression: head.compressionEnabled) }
            }
        }

        func start(_ slot: LocalOutgoingAttachment, key: ConversationKey, compression: Bool) {
            guard !slot.isUploaded, slot.failure == nil, slot.retryNotBefore.map({ $0 <= date }) ?? true
            else { return }
            let id = SlotIdentity(slot, accountGeneration: current)
            guard fileWorkers[id] == nil else { return }
            let work = AttachmentWork(key: key, slot: slot, compression: compression)
            if work.needsPreparation {
                guard prepares < 1 else { return }
                prepares += 1
            } else {
                guard uploads < 2 else { return }
                uploads += 1
            }
            fileWorkers[id] = (store.directory, work, Task { [weak self] in
                guard let self else { return }
                await self.runAttachment(work, id: id, store: store, generation: current)
                self.fileWorkers[id] = nil
                if current == self.generation,
                    !self.fileWorkers.keys.contains(where: {
                        $0.accountGeneration == current && $0.id == id.id
                    })
                {
                    self.updateProgress(nil, slotID: id.id, key: key)
                }
                self.wakeWorkers()
                self.scheduleFileCleanup()
            })
        }
    }

    private func attachmentOwner(_ key: ConversationKey, _ id: SlotIdentity) -> (itemID: String?, found: Bool) {
        guard let snapshot = snapshots[key] else { return (nil, false) }
        for item in snapshot.outgoing where item.state == .pending || item.failure?.stage == .preparation {
            if !removing.contains(item.clientGeneratedID), item.attachments.contains(where: id.matches) {
                return (item.clientGeneratedID, true)
            }
        }
        return (nil, snapshot.draft.attachments.contains(where: id.matches))
    }

    private func runAttachment(
        _ work: AttachmentWork, id: SlotIdentity, store: ChahuaLocalStore, generation current: UInt64
    ) async {
        do {
            try checkGeneration(current)
            guard canDispatch, allowsExecution, attachmentOwner(work.key, id).found,
                work.slot.retryNotBefore.map({ $0 <= Date() }) ?? true
            else { return }
            let attachment: LocalOutgoingAttachment
            if work.needsPreparation {
                attachment = try await OutgoingImageProcessor(directory: store.directory)
                    .prepare(work.slot, compressionEnabled: work.compression)
            } else {
                attachment = try await upload(work, id: id, directory: store.directory, generation: current)
            }
            try await checkpointAttachment(attachment, work: work, failure: nil, generation: current)
        } catch is CancellationError {
        } catch {
            let retryAfter = Self.retryAfter(from: error)
            guard current == generation, (!Task.isCancelled || retryAfter != nil),
                attachmentOwner(work.key, id).found
            else { return }
            let failure = Self.failure(error, stage: .preparation)
            if failure.reason == .authentication { authenticationFailed = true }
            var slot = work.slot
            slot.failure = failure.reason
            slot.retryNotBefore = retryAfter
            do {
                try await checkpointAttachment(slot, work: work, failure: failure, generation: current)
            } catch {
                storageFailed(error, generation: current)
            }
            if current == generation, failure.reason == .authentication { await onInvalidToken() }
        }
    }

    private struct AttachmentSizeError: Error { let limit: Int64 }

    private func upload(
        _ work: AttachmentWork, id: SlotIdentity, directory: URL, generation current: UInt64
    ) async throws -> LocalOutgoingAttachment {
        var slot = work.slot
        let config = try await apiClient.attachmentConfig()
        try checkGeneration(current)
        guard attachmentOwner(work.key, id).found else { throw CancellationError() }
        guard slot.byteCount <= config.maxFileSizeBytes else {
            throw AttachmentSizeError(limit: config.maxFileSizeBytes)
        }
        let allocation = try await apiClient.requestAttachmentUpload(
            fileName: slot.fileName, contentType: slot.mimeType,
            purpose: slot.isFile ? .file : slot.isAudio ? .voice : .media,
            size: slot.byteCount, width: slot.width, height: slot.height, order: slot.position)
        try checkGeneration(current)
        guard attachmentOwner(work.key, id).found else { throw CancellationError() }
        try await uploadFile(directory, URL(fileURLWithPath: slot.uploadPath), allocation) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.fileWorkers[id] != nil,
                    self.attachmentOwner(work.key, id).found
                else { return }
                if progress == 1 || abs(progress - self.attachmentProgress[id.id, default: -1]) >= 0.01 {
                    self.updateProgress(progress, slotID: id.id, key: work.key)
                }
            }
        }
        slot.attachmentID = allocation.attachmentId
        slot.retryNotBefore = nil
        return slot
    }

    private func updateProgress(_ value: Double?, slotID: String, key: ConversationKey) {
        guard attachmentProgress[slotID] != value else { return }
        attachmentProgress[slotID] = value
        if let snapshot = snapshots[key],
            snapshot.outgoing.contains(where: { item in
                item.state == .pending && item.attachments.contains { $0.id == slotID }
            })
        {
            events.send(.snapshot(snapshot))
        }
    }

    private func checkpointAttachment(
        _ slot: LocalOutgoingAttachment, work: AttachmentWork, failure: OutboxFailure?,
        generation current: UInt64
    ) async throws {
        // A transfer that already succeeded must keep its ID even if its
        // execution opportunity closed just before this checkpoint.
        guard current == generation, failure == nil || slot.retryNotBefore != nil || !Task.isCancelled
        else { throw CancellationError() }
        try await ordered {
            try self.checkGeneration(current)
            let owner = self.attachmentOwner(
                work.key, SlotIdentity(slot, accountGeneration: current))
            guard owner.found, let store = self.storage.store else { return }
            let snapshot: LocalConversationSnapshot
            do {
                snapshot = try await store.checkpointAttachment(
                    key: work.key, itemID: owner.itemID, attachment: slot, failure: failure)
            } catch {
                self.storageFailed(error, generation: current)
                return
            }
            try self.checkGeneration(current)
            if let id = owner.itemID,
                let item = snapshot.outgoing.first(where: { $0.clientGeneratedID == id })
            {
                if let failure {
                    self.recordRetryWindow(id: id, failure: item.failure ?? failure)
                } else if slot.isUploaded && item.state == .pending {
                    self.retryWindows[id] = nil
                }
            }
            self.publish(snapshot)
            self.wakeWorkers()
        }
    }

    private func withFileLease<T: Sendable>(
        in directory: URL, _ operation: @MainActor () async throws -> T
    ) async rethrows -> T {
        fileLeases[directory, default: 0] += 1
        defer {
            let remaining = fileLeases[directory, default: 1] - 1
            fileLeases[directory] = remaining > 0 ? remaining : nil
            if remaining == 0, let waiters = fileDrainWaiters.removeValue(forKey: directory) {
                for waiter in waiters { waiter.resume() }
            }
            scheduleFileCleanup()
        }
        return try await operation()
    }

    private func scheduleFileCleanup() {
        guard cleanup == nil, storageState == .ready, let store = storage.store else { return }
        let current = generation
        cleanup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.generation == current else { return }
            var postpone = false
            defer {
                if self.generation == current {
                    self.cleanup = nil
                    if postpone { self.scheduleFileCleanup() }
                }
            }
            guard self.storageState == .ready else { return }
            guard self.fileLeases[store.directory] == nil,
                !self.fileWorkers.values.contains(where: { $0.directory == store.directory })
            else {
                postpone = true
                return
            }
            var retained = Set<String>()
            func retain(_ slots: [LocalOutgoingAttachment]) {
                for slot in slots {
                    retained.insert(slot.sourcePath)
                    retained.insert(slot.previewPath)
                    if let path = slot.preparedPath { retained.insert(path) }
                }
            }
            for snapshot in self.snapshots.values {
                retain(snapshot.draft.attachments)
                for item in snapshot.outgoing { retain(item.attachments) }
            }
            for editor in self.editors.values { retain(editor.attachments) }
            try? await OutgoingFileCleanup.reclaim(
                directory: store.directory, retaining: retained, olderThan: Date().addingTimeInterval(-60))
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
