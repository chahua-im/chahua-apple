import Combine
import Foundation
import ChahuaAPI
import os

@MainActor
enum ChatListLoadPhase: Equatable {
    case idle, loading, loaded, failed
}

struct ChatState: Equatable {
    var chats: [ChatListItem] = []
    var chatListLoadPhase: ChatListLoadPhase = .idle
    var chatListRefreshFailed = false
    var isRefreshingChats = false
    var threads: [ThreadListItem] = []
    var threadListLoadPhase: ChatListLoadPhase = .idle
    var threadListRefreshFailed = false
    var isRefreshingThreads = false
}

@MainActor
final class ChatStore: ObservableObject {
    private static let logger = Logger(subsystem: "app.chahua.chat", category: "conversations")
    @Published private(set) var state = ChatState()
    @Published var currentUserProfile: MeResponse?
    let conversationMessages = ConversationMessageStore()
    let outgoingQueue: OutgoingMessageQueue
    let reactions: MessageReactionController
    let drafts: ChatDraftStore
    private var outgoingObservation: AnyCancellable?
    private var storageObservation: AnyCancellable?
    private var outgoingRevisions: [ConversationKey: Int64] = [:]

    private let apiClient: any ChahuaAPIClient
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var generation = 0
    private var readStateRevision = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var invalidationTask: Task<Void, Never>?
    private var refreshDirty = false
    private var threadRefreshTask: Task<Void, Never>?
    private var threadRefreshDirty = false
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
        drafts = ChatDraftStore(outgoingQueue: outgoingQueue)
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
            guard installOutgoingSnapshot(snapshot) else { return }
            conversationMessages.replacePending(chatID: snapshot.chatID, threadID: snapshot.threadID, with: pendingProjection(chatID: snapshot.chatID, threadID: snapshot.threadID))
        case .acknowledged(let snapshot, let message):
            if let snapshot { _ = installOutgoingSnapshot(snapshot) }
            conversationMessages.replacePending(chatID: message.chatId, threadID: message.replyRootId, with: pendingProjection(chatID: message.chatId, threadID: message.replyRootId), acknowledging: message)
            invalidateChatList()
        }
    }

    @discardableResult
    private func installOutgoingSnapshot(_ snapshot: LocalConversationSnapshot) -> Bool {
        let key = ConversationKey(chatID: snapshot.chatID, threadID: snapshot.threadID)
        guard snapshot.revision >= outgoingRevisions[key, default: -1] else { return false }
        outgoingRevisions[key] = snapshot.revision
        drafts.install(snapshot)
        return true
    }

    private func pendingProjection(chatID: String, threadID: String?) -> [PendingOutgoingMessage] {
        outgoingQueue.pendingMessages(chatID: chatID, threadID: threadID).sorted { $0.enqueueSequence < $1.enqueueSequence }.map { message in
            let state: PendingOutgoingMessage.State = switch message.state {
            case .queued: .queued
            case .sending: .sending
            case .failed: .failed
            }
            return PendingOutgoingMessage(
                chatID: message.chatID, threadID: message.threadID, clientGeneratedID: message.clientGeneratedID,
                body: .init(messageType: .text, clientGeneratedId: message.clientGeneratedID, message: message.text, replyToId: message.replyToMessage?.id),
                enqueuedAt: message.enqueuedAt, senderID: message.senderID,
                state: state, replyToMessage: message.replyToMessage,
                attachments: message.attachments, dispatchClaimed: message.dispatchClaimed,
                editRevision: message.editRevision
            )
        }
    }

    func retryLocalStorage() async {
        let requestGeneration = generation
        await outgoingQueue.retryStorage()
        guard generation == requestGeneration else { return }
        await drafts.flushAll()
    }

    func setForegroundActive(_ active: Bool) {
        outgoingQueue.requestForegroundActive(active)
        if !active {
            drafts.scheduleBackgroundFlush()
        }
    }

    func loadActiveChats() async {
        guard state.chatListLoadPhase == .idle || state.chatListLoadPhase == .failed else { return }
        await refreshActiveChats()
    }

    func refreshActiveChats() async {
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
        let readRevision = readStateRevision
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
            guard readStateRevision == readRevision else {
                refreshDirty = true
                return
            }
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

    func loadActiveThreads() async {
        guard state.threadListLoadPhase == .idle || state.threadListLoadPhase == .failed else { return }
        await refreshActiveThreads()
    }

    func refreshActiveThreads() async {
        if let threadRefreshTask {
            await threadRefreshTask.value
            return
        }
        let requestGeneration = generation
        let currentRefresh = refreshGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == requestGeneration && self.refreshGeneration == currentRefresh {
                    self.threadRefreshTask = nil
                    self.state.isRefreshingThreads = false
                }
            }
            self.state.isRefreshingThreads = true
            repeat {
                self.threadRefreshDirty = false
                let initiallyLoaded = self.state.threadListLoadPhase == .loaded
                let readRevision = self.readStateRevision
                if !initiallyLoaded { self.state.threadListLoadPhase = .loading }
                do {
                    var threads: [ThreadListItem] = []
                    var seen = Set<ConversationKey>()
                    var cursors = Set<String>()
                    var cursor: String?
                    repeat {
                        let response = try await self.apiClient.listThreads(query: .init(before: cursor, archived: false))
                        try Task.checkCancellation()
                        guard self.generation == requestGeneration, self.refreshGeneration == currentRefresh else { return }
                        for thread in response.threads {
                            let key = ConversationKey(chatID: thread.chatId, threadID: thread.threadRootMessage.id)
                            if seen.insert(key).inserted { threads.append(thread) }
                        }
                        cursor = response.nextCursor
                        if let cursor, !cursors.insert(cursor).inserted {
                            Self.logger.error("Thread list refresh failed: server repeated a pagination cursor")
                            throw APIError.unavailable
                        }
                    } while cursor != nil
                    guard self.readStateRevision == readRevision else {
                        self.threadRefreshDirty = true
                        continue
                    }
                    self.state.threads = threads
                    self.state.threadListLoadPhase = .loaded
                    self.state.threadListRefreshFailed = false
                } catch {
                    guard self.generation == requestGeneration, self.refreshGeneration == currentRefresh else { return }
                    if error is CancellationError {
                        if !initiallyLoaded { self.state.threadListLoadPhase = .idle }
                        return
                    }
                    self.state.threadListRefreshFailed = initiallyLoaded
                    if !initiallyLoaded { self.state.threadListLoadPhase = .failed }
                    if case APIError.invalidToken = error { await self.onInvalidToken() }
                }
            } while self.generation == requestGeneration && self.threadRefreshDirty && !Task.isCancelled
        }
        threadRefreshTask = task
        await task.value
    }

    func refreshActiveConversations() async {
        async let chats: Void = refreshActiveChats()
        async let threads: Void = refreshActiveThreads()
        _ = await (chats, threads)
    }

    /// Threads may belong to an archived parent absent from the active chat list.
    func chatForThread(_ thread: ThreadListItem) async throws -> ChatListItem {
        if let chat = state.chats.first(where: { $0.id == thread.chatId }) { return chat }
        let requestGeneration = generation
        do {
            let info = try await apiClient.groupInfo(chatID: thread.chatId)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            guard info.id == thread.chatId else {
                Self.logger.error("Thread parent load failed: server returned a different chat")
                throw APIError.unexpectedResponse
            }
            return ChatListItem(
                id: thread.chatId, name: thread.chatName, avatar: thread.chatAvatar,
                unreadCount: 0, archived: false, kind: info.kind, peer: info.peer)
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
        }
    }

    private func invalidateChatList() {
        if refreshTask != nil { refreshDirty = true }
        if threadRefreshTask != nil { threadRefreshDirty = true }
        let refreshChats = refreshTask == nil
        let refreshThreads = threadRefreshTask == nil
        guard refreshChats || refreshThreads else { return }
        guard invalidationTask == nil else { return }
        let requestGeneration = generation
        invalidationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.generation == requestGeneration else { return }
            self.invalidationTask = nil
            await withTaskGroup(of: Void.self) { group in
                if refreshChats { group.addTask { await self.refreshActiveChats() } }
                if refreshThreads { group.addTask { await self.refreshActiveThreads() } }
            }
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
            drafts.redactReplyTargets([message.id], chatID: message.chatId)
            conversationMessages.apply(.messageDeleted(message.normalizedForRealtime(currentUserID: currentUserID).redactedForDeletion()))
            invalidateChatList()
        case .reactionUpdated(let payload):
            conversationMessages.apply(.reactionUpdated(ReactionUpdatePayload(
                messageId: payload.messageId, chatId: payload.chatId,
                reactions: payload.reactions.map { $0.normalizedForRealtime(currentUserID: currentUserID) }
            )))
        case .messagesBulkDeleted(let payload):
            drafts.redactReplyTargets(Set(payload.messageIds), chatID: payload.chatId)
            conversationMessages.apply(event)
            invalidateChatList()
            scheduleRecovery(chatID: payload.chatId)
        case .threadUpdate:
            conversationMessages.apply(event)
            invalidateChatList()
        case .chatArchiveStateChanged, .threadMembershipChanged, .friendRequestResolved, .friendshipRemoved:
            invalidateChatList()
        case .pong, .presenceUpdate, .pinAdded, .threadPinAdded,
             .pinRemoved, .threadPinRemoved, .stickerPackOrderUpdated, .friendRequestReceived:
            break
        case .unknown:
            break
        }
    }

    func updateMessage(_ message: MessageResponse, text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != message.message?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        let requestGeneration = generation
        let optimistic = message.replacingMessageText(text)
        conversationMessages.apply(.messageUpdated(optimistic))
        do {
            let updated = try await apiClient.updateMessage(
                chatID: message.chatId, messageID: message.id, body: .init(message: text))
            guard generation == requestGeneration else { return false }
            conversationMessages.apply(.messageUpdated(updated))
            invalidateChatList()
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            conversationMessages.apply(.messageUpdated(message))
            if case APIError.invalidToken = error { await onInvalidToken() }
            return false
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

    func markRead(chatID: String, threadID: String?, messageID: String) async throws {
        try Task.checkCancellation()
        let requestGeneration = generation
        do {
            let response: ReadStateResponse
            if let threadID {
                response = try await apiClient.markThreadRead(chatID: chatID, threadID: threadID, messageID: messageID)
            } else {
                response = try await apiClient.markChatRead(chatID: chatID, messageID: messageID)
            }
            guard generation == requestGeneration else { throw CancellationError() }
            readStateRevision += 1
            if let threadID,
               let index = state.threads.firstIndex(where: { $0.chatId == chatID && $0.threadRootMessage.id == threadID }) {
                let thread = state.threads[index]
                state.threads[index] = ThreadListItem(
                    chatId: thread.chatId, chatName: thread.chatName, chatAvatar: thread.chatAvatar,
                    threadRootMessage: thread.threadRootMessage, participants: thread.participants,
                    lastReply: thread.lastReply, replyCount: thread.replyCount, lastReplyAt: thread.lastReplyAt,
                    unreadCount: response.unreadCount, lastReadMessageId: response.lastReadMessageId,
                    subscribedAt: thread.subscribedAt, archived: thread.archived)
            } else if threadID == nil, let index = state.chats.firstIndex(where: { $0.id == chatID }) {
                let chat = state.chats[index]
                state.chats[index] = ChatListItem(
                    id: chat.id, name: chat.name, avatar: chat.avatar, lastMessageAt: chat.lastMessageAt,
                    unreadCount: response.unreadCount, lastReadMessageId: response.lastReadMessageId,
                    lastMessage: chat.lastMessage, mutedUntil: chat.mutedUntil, archived: chat.archived,
                    kind: chat.kind, peer: chat.peer)
            }
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
        threadRefreshTask?.cancel()
        threadRefreshTask = nil
        threadRefreshDirty = false
        state.isRefreshingThreads = false
        if state.threadListLoadPhase == .loading { state.threadListLoadPhase = .idle }
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
        drafts.reset()
        outgoingRevisions.removeAll()
        cancelRealtimeRecovery()
        reactions.reset()
        conversationMessages.reset()
        state = ChatState()
    }
}
