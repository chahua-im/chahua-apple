import Combine
import Foundation
import ChahuaAPI

@MainActor
enum ChatListLoadPhase: Equatable {
    case idle, loading, loaded, failed
}

struct ChatState: Equatable {
    var chats: [ChatListItem] = []
    var chatListLoadPhase: ChatListLoadPhase = .idle
    var chatListRefreshFailed = false
    var isRefreshingChats = false
}

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var state = ChatState()
    let conversationMessages = ConversationMessageStore()
    let outgoingQueue: OutgoingMessageQueue
    let reactions: MessageReactionController
    @Published private(set) var drafts: [String: String] = [:]
    @Published private(set) var committingDrafts = Set<String>()
    @Published private(set) var draftSaveFailed = false
    private var draftRevisions: [String: Int64] = [:]
    private var unsavedDrafts = Set<String>()
    private var pendingDraftSaves: [String: Task<Void, Never>] = [:]
    private var outgoingObservation: AnyCancellable?
    private var storageObservation: AnyCancellable?
    private var outgoingRevisions: [String: Int64] = [:]

    private let apiClient: any ChahuaAPIClient
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var invalidationTask: Task<Void, Never>?
    private var refreshDirty = false
    private var recoveryTasks: [String: Task<Void, Never>] = [:]
    private var recoveryDirty = Set<String>()
    private var recoveryGeneration = 0
    private var timelines: [ObjectIdentifier: WeakTimeline] = [:]

    private struct WeakTimeline {
        weak var value: ConversationTimelineModel?
    }

    init(apiClient: any ChahuaAPIClient, outgoingQueue: OutgoingMessageQueue, onInvalidToken: @escaping @MainActor @Sendable () async -> Void) {
        self.apiClient = apiClient
        self.onInvalidToken = onInvalidToken
        self.outgoingQueue = outgoingQueue
        reactions = MessageReactionController(
            apiClient: apiClient, messageStore: conversationMessages, onInvalidToken: onInvalidToken
        )
        outgoingObservation = outgoingQueue.events.sink { [weak self] event in
            self?.applyOutgoingEvent(event)
        }
        storageObservation = outgoingQueue.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func applyOutgoingEvent(_ event: OutgoingQueueEvent) {
        switch event {
        case .snapshot(let snapshot):
            guard installDraft(snapshot) else { return }
            conversationMessages.replacePending(chatID: snapshot.chatID, with: pendingProjection(chatID: snapshot.chatID))
        case .acknowledged(let snapshot, let message):
            if let snapshot { _ = installDraft(snapshot) }
            conversationMessages.replacePending(chatID: message.chatId, with: pendingProjection(chatID: message.chatId), acknowledging: message)
            invalidateChatList()
        }
    }

    @discardableResult
    private func installDraft(_ snapshot: LocalConversationSnapshot) -> Bool {
        guard snapshot.revision >= outgoingRevisions[snapshot.chatID, default: -1] else { return false }
        outgoingRevisions[snapshot.chatID] = snapshot.revision
        if unsavedDrafts.contains(snapshot.chatID), !committingDrafts.contains(snapshot.chatID),
           drafts[snapshot.chatID] != snapshot.draft.text {
            draftRevisions[snapshot.chatID] = max(draftRevisions[snapshot.chatID, default: 0], snapshot.draft.editRevision + 1)
        } else if snapshot.draft.editRevision >= draftRevisions[snapshot.chatID, default: 0] {
            drafts[snapshot.chatID] = snapshot.draft.text
            draftRevisions[snapshot.chatID] = snapshot.draft.editRevision
            unsavedDrafts.remove(snapshot.chatID)
        }
        return true
    }

    private func pendingProjection(chatID: String) -> [PendingOutgoingMessage] {
        outgoingQueue.pendingMessages(chatID: chatID).sorted { $0.enqueueSequence < $1.enqueueSequence }.map { message in
            let state: PendingOutgoingMessage.State = switch message.state {
            case .queued: .queued
            case .sending: .sending
            case .failed: .failed
            }
            return PendingOutgoingMessage(
                chatID: message.chatID, clientGeneratedID: message.clientGeneratedID,
                body: .init(messageType: .text, clientGeneratedId: message.clientGeneratedID, message: message.text),
                enqueuedAt: message.enqueuedAt, senderID: message.senderID,
                state: state
            )
        }
    }

    func draftText(chatID: String) -> String { drafts[chatID, default: ""] }

    func setDraftText(_ text: String, chatID: String) {
        guard !committingDrafts.contains(chatID), drafts[chatID] != text else { return }
        drafts[chatID] = text
        unsavedDrafts.insert(chatID)
        draftRevisions[chatID, default: 0] += 1
        pendingDraftSaves[chatID]?.cancel()
        pendingDraftSaves[chatID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            self?.pendingDraftSaves[chatID] = nil
            await self?.flushDraft(chatID: chatID)
        }
    }

    func flushDraft(chatID: String) async {
        pendingDraftSaves.removeValue(forKey: chatID)?.cancel()
        guard let text = drafts[chatID], unsavedDrafts.contains(chatID), !committingDrafts.contains(chatID) else { return }
        let revision = draftRevisions[chatID, default: 0]
        let requestGeneration = generation
        do {
            try await outgoingQueue.saveDraft(chatID: chatID, text: text, editRevision: revision, updatedAt: Date())
            guard generation == requestGeneration else { return }
            draftSaveFailed = false
        } catch {
            guard generation == requestGeneration else { return }
            draftSaveFailed = true
        }
    }

    func submitDraft(chatID: String) async -> Bool {
        let text = draftText(chatID: chatID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !committingDrafts.contains(chatID), outgoingQueue.storageState == .ready else { return false }
        pendingDraftSaves.removeValue(forKey: chatID)?.cancel()
        committingDrafts.insert(chatID)
        let requestGeneration = generation
        let revision = draftRevisions[chatID, default: 0] + 1
        defer { if generation == requestGeneration { committingDrafts.remove(chatID) } }
        do {
            try await outgoingQueue.enqueueText(chatID: chatID, text: text, clearedDraftRevision: revision)
            guard generation == requestGeneration else { return false }
            draftRevisions[chatID] = revision
            drafts[chatID] = ""
            unsavedDrafts.remove(chatID)
            draftSaveFailed = false
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            draftSaveFailed = true
            return false
        }
    }

    func retryLocalStorage() async {
        await outgoingQueue.retryStorage()
        for chatID in Array(drafts.keys) { await flushDraft(chatID: chatID) }
    }

    func setForegroundActive(_ active: Bool) {
        outgoingQueue.requestForegroundActive(active)
        if !active {
            for chatID in drafts.keys {
                pendingDraftSaves[chatID]?.cancel()
                pendingDraftSaves[chatID] = Task { [weak self] in
                    self?.pendingDraftSaves[chatID] = nil
                    await self?.flushDraft(chatID: chatID)
                }
            }
        }
    }

    func loadActiveChats() async {
        guard state.chatListLoadPhase == .idle || state.chatListLoadPhase == .failed else { return }
        await refreshActiveChats()
    }

    func refreshActiveChats() async {
        invalidationTask?.cancel()
        invalidationTask = nil
        if let refreshTask {
            await refreshTask.value
            return
        }
        let requestGeneration = generation
        let currentRefresh = refreshGeneration
        let task = Task { [weak self] in
            guard let self, self.refreshGeneration == currentRefresh, !Task.isCancelled else { return }
            defer {
                if self.generation == requestGeneration && self.refreshGeneration == currentRefresh {
                    self.refreshTask = nil
                    self.state.isRefreshingChats = false
                }
            }
            self.state.isRefreshingChats = true
            repeat {
                self.refreshDirty = false
                await self.refreshSnapshot(generation: requestGeneration, refreshGeneration: currentRefresh)
            } while self.generation == requestGeneration && self.refreshDirty && !Task.isCancelled
        }
        refreshTask = task
        await task.value
    }

    private func refreshSnapshot(generation requestGeneration: Int, refreshGeneration currentRefresh: Int) async {
        let initiallyLoaded = state.chatListLoadPhase == .loaded
        if !initiallyLoaded { state.chatListLoadPhase = .loading }
        do {
            var chats: [ChatListItem] = []
            var seenIDs = Set<String>()
            var cursors = Set<String>()
            var cursor: String?
            repeat {
                let response = try await apiClient.listChats(query: ListChatsQuery(after: cursor, archived: false))
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                for chat in response.chats where seenIDs.insert(chat.id).inserted { chats.append(chat) }
                cursor = response.nextCursor
                if let cursor, !cursors.insert(cursor).inserted { throw APIError.unavailable }
            } while cursor != nil
            state.chats = chats
            state.chatListLoadPhase = .loaded
            state.chatListRefreshFailed = false
        } catch {
            guard generation == requestGeneration, refreshGeneration == currentRefresh else { return }
            if error is CancellationError {
                if !initiallyLoaded { state.chatListLoadPhase = .idle }
                return
            }
            state.chatListRefreshFailed = initiallyLoaded
            if !initiallyLoaded { state.chatListLoadPhase = .failed }
            if case APIError.invalidToken = error { await onInvalidToken() }
        }
    }

    private func invalidateChatList() {
        if refreshTask != nil {
            refreshDirty = true
            return
        }
        guard invalidationTask == nil else { return }
        let requestGeneration = generation
        invalidationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.generation == requestGeneration else { return }
            self.invalidationTask = nil
            await self.refreshActiveChats()
        }
    }

    func applyRealtimeEvent(_ event: RealtimeServerEvent, currentUserID: Int32) async {
        switch event {
        case .message(let message):
            let requestGeneration = generation
            let normalized = message.normalizedForRealtime(currentUserID: currentUserID)
            let handled = await outgoingQueue.acceptAcknowledgement(normalized)
            guard generation == requestGeneration else { return }
            if !handled { conversationMessages.apply(.message(normalized)) }
            invalidateChatList()
        case .messageUpdated(let message):
            conversationMessages.apply(.messageUpdated(message.normalizedForRealtime(currentUserID: currentUserID)))
            invalidateChatList()
        case .messageDeleted(let message):
            conversationMessages.apply(.messageDeleted(message.normalizedForRealtime(currentUserID: currentUserID).redactedForDeletion()))
            invalidateChatList()
        case .reactionUpdated(let payload):
            conversationMessages.apply(.reactionUpdated(ReactionUpdatePayload(
                messageId: payload.messageId, chatId: payload.chatId,
                reactions: payload.reactions.map { $0.normalizedForRealtime(currentUserID: currentUserID) }
            )))
        case .messagesBulkDeleted(let payload):
            conversationMessages.apply(event)
            invalidateChatList()
            scheduleRecovery(chatID: payload.chatId)
        case .threadUpdate:
            conversationMessages.apply(event)
        case .chatArchiveStateChanged:
            invalidateChatList()
        case .pong, .presenceUpdate, .threadMembershipChanged, .pinAdded, .threadPinAdded,
             .pinRemoved, .threadPinRemoved, .stickerPackOrderUpdated, .friendRequestReceived,
             .friendRequestResolved, .friendshipRemoved:
            break
        case .unknown:
            break
        }
    }

    func registerTimeline(_ model: ConversationTimelineModel) {
        timelines[ObjectIdentifier(model)] = WeakTimeline(value: model)
    }

    func unregisterTimeline(_ model: ConversationTimelineModel) {
        timelines.removeValue(forKey: ObjectIdentifier(model))
    }

    func reconcileVisibleTimelines() async {
        let models = visibleTimelines()
        await withTaskGroup(of: Void.self) { group in
            for model in models { group.addTask { await model.reconcileAfterReconnect() } }
        }
    }

    private func visibleTimelines() -> [ConversationTimelineModel] {
        timelines = timelines.filter { $0.value.value != nil }
        return timelines.values.compactMap(\.value)
    }

    private func scheduleRecovery(chatID: String) {
        recoveryDirty.insert(chatID)
        guard recoveryTasks[chatID] == nil else { return }
        let requestGeneration = generation
        let currentRecovery = recoveryGeneration
        recoveryTasks[chatID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == requestGeneration && self.recoveryGeneration == currentRecovery {
                    self.recoveryTasks[chatID] = nil
                }
            }
            repeat {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard self.generation == requestGeneration, self.recoveryGeneration == currentRecovery else { return }
                self.recoveryDirty.remove(chatID)
                let models = self.visibleTimelines().filter { $0.chatID == chatID }
                await withTaskGroup(of: Void.self) { group in
                    for model in models { group.addTask { await model.reconcileAfterReconnect() } }
                }
            } while !Task.isCancelled && self.recoveryDirty.contains(chatID)
        }
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery = .init()) async throws -> ListMessagesResponse {
        let requestGeneration = generation
        do {
            let response = try await apiClient.listMessages(chatID: chatID, query: query)
            guard generation == requestGeneration else { throw CancellationError() }
            for message in response.messages {
                _ = await outgoingQueue.acceptAcknowledgement(message)
                guard generation == requestGeneration else { throw CancellationError() }
            }
            return response
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
        }
    }

    func cancelRealtimeRecovery() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        invalidationTask?.cancel()
        invalidationTask = nil
        refreshDirty = false
        state.isRefreshingChats = false
        if state.chatListLoadPhase == .loading { state.chatListLoadPhase = .idle }
        recoveryGeneration += 1
        recoveryDirty.removeAll()
        for task in recoveryTasks.values { task.cancel() }
        recoveryTasks.removeAll()
    }

    func reset() {
        generation += 1
        for task in pendingDraftSaves.values { task.cancel() }
        pendingDraftSaves.removeAll()
        drafts.removeAll()
        draftRevisions.removeAll()
        unsavedDrafts.removeAll()
        outgoingRevisions.removeAll()
        committingDrafts.removeAll()
        draftSaveFailed = false
        cancelRealtimeRecovery()
        reactions.reset()
        conversationMessages.reset()
        state = ChatState()
    }
}
