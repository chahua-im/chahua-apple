import ChahuaAPI
import Combine
import Foundation
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
    var archivedChats: [ChatListItem] = []
    var archivedChatListLoadPhase: ChatListLoadPhase = .idle
    var archivedChatListRefreshFailed = false
    var isRefreshingArchivedChats = false
    var archivedThreads: [ThreadListItem] = []
    var archivedThreadListLoadPhase: ChatListLoadPhase = .idle
    var archivedThreadListRefreshFailed = false
    var isRefreshingArchivedThreads = false
}

@MainActor
final class ChatStore: ObservableObject {
    private static let logger = Logger(subsystem: "app.chahua.chat", category: "conversations")
    @Published private(set) var state = ChatState()
    @Published var currentUserProfile: MeResponse? {
        didSet { stickers.setPackOrder(currentUserProfile?.stickerPackOrder ?? []) }
    }
    @Published private(set) var pendingListActions = [ConversationKey: ConversationListAction]()
    @Published var listActionError: String?
    @Published private(set) var deletingMessageIDs = Set<String>()
    let conversationMessages = ConversationMessageStore()
    let outgoingQueue: OutgoingMessageQueue
    let reactions: MessageReactionController
    let pins: ChatPinController
    let drafts: ChatDraftStore
    let stickers: StickerLibrary
    var onNotificationRead: ((ConversationKey, String) -> Void)?
    private var outgoingObservation: AnyCancellable?
    private var storageObservation: AnyCancellable?
    private var outgoingRevisions: [ConversationKey: Int64] = [:]

    private let apiClient: any ChahuaAPIClient
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var generation = 0
    private var listStateRevision = 0
    private var refreshTasks: [ListKind: Task<Void, Never>] = [:]
    private var refreshGeneration = 0
    private var invalidationTask: Task<Void, Never>?
    private var dirtyLists = Set<ListKind>()
    private var recoveryTasks: [String: Task<Void, Never>] = [:]
    private var recoveryDirty = Set<String>()
    private var recoveryGeneration = 0
    private var timelines: [ObjectIdentifier: WeakTimeline] = [:]
    private var groupMutationStates: [String: GroupMutationState] = [:]

    private struct GroupMutationState {
        var token: UUID
        var waiters: [CheckedContinuation<UUID, Never>]
    }

    private func serializeGroupMutation<Result>(
        chatID: String, operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        let token = await acquireGroupMutation(chatID: chatID)
        defer { releaseGroupMutation(chatID: chatID, token: token) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquireGroupMutation(chatID: String) async -> UUID {
        if var state = groupMutationStates[chatID] {
            return await withCheckedContinuation { continuation in
                state.waiters.append(continuation)
                groupMutationStates[chatID] = state
            }
        }
        let token = UUID()
        groupMutationStates[chatID] = .init(token: token, waiters: [])
        return token
    }

    private func releaseGroupMutation(chatID: String, token: UUID) {
        guard var state = groupMutationStates[chatID], state.token == token else { return }
        guard !state.waiters.isEmpty else {
            groupMutationStates.removeValue(forKey: chatID)
            return
        }
        let next = state.waiters.removeFirst()
        let nextToken = UUID()
        state.token = nextToken
        groupMutationStates[chatID] = state
        next.resume(returning: nextToken)
    }

    private func cancelQueuedGroupMutations() {
        let waiters = groupMutationStates.values.flatMap { $0.waiters }
        groupMutationStates.removeAll()
        for waiter in waiters { waiter.resume(returning: UUID()) }
    }

    private func performGroupRequest<Result>(
        generation requestGeneration: Int, operation: () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        do {
            let response = try await operation()
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            return response
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
        }
    }

    private struct WeakTimeline {
        weak var value: ConversationTimelineModel?
    }

    private enum ListKind: CaseIterable, Hashable {
        case chats, threads, archivedChats, archivedThreads

        var archived: Bool { self == .archivedChats || self == .archivedThreads }

        var phase: WritableKeyPath<ChatState, ChatListLoadPhase> {
            switch self {
            case .chats: \.chatListLoadPhase
            case .threads: \.threadListLoadPhase
            case .archivedChats: \.archivedChatListLoadPhase
            case .archivedThreads: \.archivedThreadListLoadPhase
            }
        }

        var refreshing: WritableKeyPath<ChatState, Bool> {
            switch self {
            case .chats: \.isRefreshingChats
            case .threads: \.isRefreshingThreads
            case .archivedChats: \.isRefreshingArchivedChats
            case .archivedThreads: \.isRefreshingArchivedThreads
            }
        }

        var refreshFailed: WritableKeyPath<ChatState, Bool> {
            switch self {
            case .chats: \.chatListRefreshFailed
            case .threads: \.threadListRefreshFailed
            case .archivedChats: \.archivedChatListRefreshFailed
            case .archivedThreads: \.archivedThreadListRefreshFailed
            }
        }
    }

    init(
        apiClient: any ChahuaAPIClient, outgoingQueue: OutgoingMessageQueue,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.apiClient = apiClient
        self.onInvalidToken = onInvalidToken
        self.outgoingQueue = outgoingQueue
        drafts = ChatDraftStore(outgoingQueue: outgoingQueue)
        reactions = MessageReactionController(
            apiClient: apiClient, messageStore: conversationMessages, onInvalidToken: onInvalidToken
        )
        pins = ChatPinController(apiClient: apiClient, onInvalidToken: onInvalidToken)
        stickers = StickerLibrary(apiClient: apiClient, onInvalidToken: onInvalidToken)
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
            conversationMessages.replacePending(
                chatID: snapshot.chatID, threadID: snapshot.threadID,
                with: pendingProjection(chatID: snapshot.chatID, threadID: snapshot.threadID))
        case .acknowledged(let snapshot, let message):
            if let snapshot { _ = installOutgoingSnapshot(snapshot) }
            conversationMessages.replacePending(
                chatID: message.chatId, threadID: message.replyRootId,
                with: pendingProjection(chatID: message.chatId, threadID: message.replyRootId),
                acknowledging: message)
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
        outgoingQueue.pendingMessages(chatID: chatID, threadID: threadID).sorted {
            $0.enqueueSequence < $1.enqueueSequence
        }.map { message in
            let state: PendingOutgoingMessage.State =
                switch message.state {
                case .queued: .queued
                case .sending: .sending
                case .failed: .failed
                }
            return PendingOutgoingMessage(
                chatID: message.chatID, threadID: message.threadID,
                clientGeneratedID: message.clientGeneratedID,
                body: .init(
                    messageType: message.messageType,
                    clientGeneratedId: message.clientGeneratedID,
                    message: message.messageType == .text ? message.text : nil,
                    replyToId: message.replyToMessage?.id, stickerId: message.sticker?.id),
                enqueuedAt: message.enqueuedAt, senderID: message.senderID,
                state: state, replyToMessage: message.replyToMessage,
                attachments: message.attachments, dispatchClaimed: message.dispatchClaimed,
                editRevision: message.editRevision, sticker: message.sticker
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

    func loadActiveChats() async { await loadList(.chats) }
    func loadActiveThreads() async { await loadList(.threads) }
    func loadArchivedChats() async { await loadList(.archivedChats) }
    func loadArchivedThreads() async { await loadList(.archivedThreads) }

    func refreshActiveChats() async { await refreshList(.chats) }
    func refreshActiveThreads() async { await refreshList(.threads) }
    func refreshArchivedChats() async { await refreshList(.archivedChats) }
    func refreshArchivedThreads() async { await refreshList(.archivedThreads) }

    private func loadList(_ list: ListKind) async {
        let phase = state[keyPath: list.phase]
        guard phase == .idle || phase == .failed else { return }
        await refreshList(list)
    }

    private func refreshList(_ list: ListKind) async {
        if let task = refreshTasks[list] {
            await task.value
            return
        }
        let requestGeneration = generation
        let currentRefresh = refreshGeneration
        let task = Task { [weak self] in
            guard let self, self.generation == requestGeneration,
                self.refreshGeneration == currentRefresh, !Task.isCancelled
            else { return }
            defer {
                if self.generation == requestGeneration && self.refreshGeneration == currentRefresh
                {
                    self.refreshTasks[list] = nil
                    self.state[keyPath: list.refreshing] = false
                }
            }
            self.state[keyPath: list.refreshing] = true
            repeat {
                self.dirtyLists.remove(list)
                await self.refreshSnapshot(
                    list, generation: requestGeneration, refreshGeneration: currentRefresh)
            } while self.generation == requestGeneration && self.refreshGeneration == currentRefresh
                && self.dirtyLists.contains(list) && !Task.isCancelled
        }
        refreshTasks[list] = task
        await task.value
    }

    private func refreshSnapshot(
        _ list: ListKind, generation requestGeneration: Int, refreshGeneration currentRefresh: Int
    ) async {
        let initiallyLoaded = state[keyPath: list.phase] == .loaded
        let listRevision = listStateRevision
        if !initiallyLoaded { state[keyPath: list.phase] = .loading }
        do {
            switch list {
            case .chats, .archivedChats:
                let chats = try await fetchChatList(
                    archived: list.archived, generation: requestGeneration,
                    refreshGeneration: currentRefresh)
                try Task.checkCancellation()
                guard generation == requestGeneration, refreshGeneration == currentRefresh else {
                    return
                }
                guard listStateRevision == listRevision else {
                    dirtyLists.insert(list)
                    return
                }
                let ids = Set(chats.lazy.map(\.id))
                if list.archived {
                    state.chats.removeAll { ids.contains($0.id) }
                    state.archivedChats = chats
                } else {
                    state.archivedChats.removeAll { ids.contains($0.id) }
                    state.chats = chats
                }
            case .threads, .archivedThreads:
                let threads = try await fetchThreadList(
                    archived: list.archived, generation: requestGeneration,
                    refreshGeneration: currentRefresh)
                try Task.checkCancellation()
                guard generation == requestGeneration, refreshGeneration == currentRefresh else {
                    return
                }
                guard listStateRevision == listRevision else {
                    dirtyLists.insert(list)
                    return
                }
                let keys = Set(
                    threads.lazy.map {
                        ConversationKey(chatID: $0.chatId, threadID: $0.threadRootMessage.id)
                    })
                if list.archived {
                    state.threads.removeAll {
                        keys.contains(.init(chatID: $0.chatId, threadID: $0.threadRootMessage.id))
                    }
                    state.archivedThreads = threads
                } else {
                    state.archivedThreads.removeAll {
                        keys.contains(.init(chatID: $0.chatId, threadID: $0.threadRootMessage.id))
                    }
                    state.threads = threads
                }
            }
            updateTimelineReadStates()
            state[keyPath: list.phase] = .loaded
            state[keyPath: list.refreshFailed] = false
        } catch {
            guard generation == requestGeneration, refreshGeneration == currentRefresh else {
                return
            }
            if error is CancellationError {
                if !initiallyLoaded { state[keyPath: list.phase] = .idle }
                return
            }
            state[keyPath: list.refreshFailed] = initiallyLoaded
            if !initiallyLoaded { state[keyPath: list.phase] = .failed }
            if case APIError.invalidToken = error { await onInvalidToken() }
        }
    }

    private func fetchChatList(
        archived: Bool, generation requestGeneration: Int, refreshGeneration currentRefresh: Int
    ) async throws -> [ChatListItem] {
        var chats: [ChatListItem] = []
        var seenIDs = Set<String>()
        var cursors = Set<String>()
        var cursor: String?
        repeat {
            let response = try await apiClient.listChats(
                query: ListChatsQuery(after: cursor, archived: archived))
            try Task.checkCancellation()
            guard generation == requestGeneration, refreshGeneration == currentRefresh else {
                throw CancellationError()
            }
            for chat in response.chats
            where chat.archived == archived && seenIDs.insert(chat.id).inserted {
                chats.append(chat)
            }
            cursor = response.nextCursor
            if let cursor, !cursors.insert(cursor).inserted { throw APIError.unavailable }
        } while cursor != nil
        return chats
    }

    private func fetchThreadList(
        archived: Bool, generation requestGeneration: Int, refreshGeneration currentRefresh: Int
    ) async throws -> [ThreadListItem] {
        var threads: [ThreadListItem] = []
        var seen = Set<ConversationKey>()
        var cursors = Set<String>()
        var cursor: String?
        repeat {
            let response = try await apiClient.listThreads(
                query: .init(before: cursor, archived: archived))
            try Task.checkCancellation()
            guard generation == requestGeneration, refreshGeneration == currentRefresh else {
                throw CancellationError()
            }
            for thread in response.threads where thread.archived == archived {
                let key = ConversationKey(
                    chatID: thread.chatId, threadID: thread.threadRootMessage.id)
                if seen.insert(key).inserted { threads.append(thread) }
            }
            cursor = response.nextCursor
            if let cursor, !cursors.insert(cursor).inserted {
                Self.logger.error("Thread list refresh failed: server repeated a pagination cursor")
                throw APIError.unavailable
            }
        } while cursor != nil
        return threads
    }

    func refreshActiveConversations() async {
        async let chats: Void = refreshActiveChats()
        async let threads: Void = refreshActiveThreads()
        _ = await (chats, threads)
    }

    func refreshArchivedConversations() async {
        async let chats: Void = refreshArchivedChats()
        async let threads: Void = refreshArchivedThreads()
        _ = await (chats, threads)
    }

    func pendingListAction(for conversation: ConversationKey) -> ConversationListAction? {
        pendingListActions[conversation]
    }

    func performListAction(_ action: ConversationListAction, conversation: ConversationKey) async {
        guard pendingListActions[conversation] == nil else { return }
        let requestGeneration = generation
        pendingListActions[conversation] = action
        listActionError = nil
        defer {
            if generation == requestGeneration {
                pendingListActions.removeValue(forKey: conversation)
            }
        }
        do {
            try await serializeGroupMutation(chatID: conversation.chatID) {
                guard self.generation == requestGeneration else { throw CancellationError() }
                await self.performListActionRequest(
                    action, conversation: conversation, generation: requestGeneration)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            listActionError = String(localized: "Couldn’t update conversation. Please try again.")
            if case APIError.invalidToken = error { await onInvalidToken() }
        }
    }

    private func performListActionRequest(
        _ action: ConversationListAction, conversation: ConversationKey,
        generation requestGeneration: Int
    ) async {
        let item: ConversationListItem
        if let threadID = conversation.threadID {
            guard let thread = thread(chatID: conversation.chatID, threadID: threadID) else {
                return
            }
            item = .thread(thread)
        } else {
            guard let chat = chat(id: conversation.chatID) else { return }
            item = .chat(chat)
        }

        do {
            try Task.checkCancellation()
            switch action {
            case .archive, .unarchive:
                let archived = action == .archive
                if let threadID = conversation.threadID {
                    if archived {
                        try await apiClient.archiveThread(
                            chatID: conversation.chatID, threadID: threadID)
                    } else {
                        try await apiClient.unarchiveThread(
                            chatID: conversation.chatID, threadID: threadID)
                    }
                } else if archived {
                    try await apiClient.archiveChat(chatID: conversation.chatID)
                } else {
                    try await apiClient.unarchiveChat(chatID: conversation.chatID)
                }
                guard generation == requestGeneration else { return }
                // Move only after server acceptance and retain any read/preview updates
                // received while the mutation was in flight.
                switch item {
                case .chat(let original):
                    let latest = chat(id: original.id) ?? original
                    applyArchiveState(
                        to: latest, archived: archived, mutedUntil: archived ? .distantFuture : nil)
                case .thread(let original):
                    let latest =
                        thread(chatID: original.chatId, threadID: original.threadRootMessage.id)
                        ?? original
                    install(
                        ThreadListItem(
                            chatId: latest.chatId, chatName: latest.chatName,
                            chatAvatar: latest.chatAvatar,
                            threadRootMessage: latest.threadRootMessage,
                            participants: latest.participants,
                            lastReply: latest.lastReply, replyCount: latest.replyCount,
                            lastReplyAt: latest.lastReplyAt,
                            unreadCount: latest.unreadCount,
                            lastReadMessageId: latest.lastReadMessageId,
                            subscribedAt: latest.subscribedAt, archived: archived))
                }
            case .mute, .unmute:
                // Threads have no independent mute API. Never mutate their parent.
                guard case .chat(let original) = item else { return }
                let mutedUntil: Date?
                if action == .mute {
                    mutedUntil = try await apiClient.muteChat(
                        chatID: conversation.chatID, durationSeconds: nil
                    ).mutedUntil
                } else {
                    try await apiClient.unmuteChat(chatID: conversation.chatID)
                    mutedUntil = nil
                }
                guard generation == requestGeneration else { return }
                let latest = chat(id: conversation.chatID) ?? original
                // DELETE /mute also unarchives the chat.
                applyArchiveState(
                    to: latest, archived: action == .unmute ? false : latest.archived,
                    mutedUntil: mutedUntil)
            case .markRead:
                guard item.unreadCount > 0, let messageID = item.readThroughMessageID else {
                    return
                }
                try await markRead(
                    chatID: conversation.chatID, threadID: conversation.threadID,
                    messageID: messageID)
                guard generation == requestGeneration else { return }
            case .markUnread:
                guard case .chat(let chat) = item, chat.unreadCount == 0, chat.lastMessage != nil
                else { return }
                let response = try await apiClient.markChatUnread(chatID: conversation.chatID)
                guard generation == requestGeneration else { return }
                applyReadState(response, chatID: conversation.chatID, threadID: nil)
            }
            invalidateChatList()
        } catch {
            guard generation == requestGeneration, !(error is CancellationError), !Task.isCancelled
            else { return }
            listActionError = String(localized: "Couldn’t update conversation. Please try again.")
            // markRead owns its invalid-token handling, including notification cursors.
            if action != .markRead, case APIError.invalidToken = error { await onInvalidToken() }
        }
    }

    private func chat(id: String) -> ChatListItem? {
        state.chats.first { $0.id == id } ?? state.archivedChats.first { $0.id == id }
    }

    private func thread(chatID: String, threadID: String) -> ThreadListItem? {
        state.threads.first { $0.chatId == chatID && $0.threadRootMessage.id == threadID }
            ?? state.archivedThreads.first {
                $0.chatId == chatID && $0.threadRootMessage.id == threadID
            }
    }

    private func install(_ chat: ChatListItem) {
        let target: WritableKeyPath<ChatState, [ChatListItem]> =
            chat.archived ? \.archivedChats : \.chats
        let other: WritableKeyPath<ChatState, [ChatListItem]> =
            chat.archived ? \.chats : \.archivedChats
        state[keyPath: other].removeAll { $0.id == chat.id }
        if let index = state[keyPath: target].firstIndex(where: { $0.id == chat.id }) {
            state[keyPath: target][index] = chat
        } else {
            state[keyPath: target].insert(chat, at: 0)
        }
    }

    private func install(_ thread: ThreadListItem) {
        let target: WritableKeyPath<ChatState, [ThreadListItem]> =
            thread.archived ? \.archivedThreads : \.threads
        let other: WritableKeyPath<ChatState, [ThreadListItem]> =
            thread.archived ? \.threads : \.archivedThreads
        state[keyPath: other].removeAll {
            $0.chatId == thread.chatId && $0.threadRootMessage.id == thread.threadRootMessage.id
        }
        if let index = state[keyPath: target].firstIndex(where: {
            $0.chatId == thread.chatId && $0.threadRootMessage.id == thread.threadRootMessage.id
        }) {
            state[keyPath: target][index] = thread
        } else {
            state[keyPath: target].insert(thread, at: 0)
        }
    }

    private func applyArchiveState(to chat: ChatListItem, archived: Bool, mutedUntil: Date?) {
        install(
            ChatListItem(
                id: chat.id, name: chat.name, avatar: chat.avatar,
                lastMessageAt: chat.lastMessageAt,
                unreadCount: chat.unreadCount, lastReadMessageId: chat.lastReadMessageId,
                lastMessage: chat.lastMessage, mutedUntil: mutedUntil, archived: archived,
                kind: chat.kind, peer: chat.peer))
    }

    /// Threads may belong to an archived parent absent from the active chat list.
    func chatForThread(_ thread: ThreadListItem) async throws -> ChatListItem {
        if let chat = chat(id: thread.chatId) { return chat }
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

    /// Payload identifiers are only navigation hints; authorize the message and
    /// resolve its parent independently of the active (unarchived) list.
    func chatForNotification(_ route: PushNotificationRoute) async throws -> ChatListItem {
        try Task.checkCancellation()
        let requestGeneration = generation
        do {
            async let infoRequest = apiClient.groupInfo(chatID: route.chatID)
            async let messageRequest = apiClient.getMessage(
                chatID: route.chatID, messageID: route.messageID)
            let (info, message) = try await (infoRequest, messageRequest)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            guard info.id == route.chatID,
                message.chatId == route.chatID,
                message.id == route.messageID,
                message.replyRootId == route.threadID
            else {
                Self.logger.error(
                    "Notification navigation failed: server returned a different conversation or message"
                )
                throw APIError.unexpectedResponse
            }
            let cached = chat(id: info.id)
            return ChatListItem(
                id: info.id, name: info.name, avatar: info.avatar,
                lastMessageAt: cached?.lastMessageAt,
                unreadCount: cached?.unreadCount ?? 0,
                lastReadMessageId: cached?.lastReadMessageId,
                lastMessage: cached?.lastMessage,
                mutedUntil: cached?.mutedUntil,
                archived: cached?.archived ?? false,
                kind: info.kind, peer: info.peer)
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
        }
    }

    private func invalidateChatList() {
        // Every invalidation fences all four snapshots, including membership changes
        // whose realtime payload carries identifiers but not the new archive state.
        listStateRevision += 1
        dirtyLists.formUnion(ListKind.allCases)
        guard invalidationTask == nil else { return }
        let requestGeneration = generation
        let currentRefresh = refreshGeneration
        invalidationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.generation == requestGeneration,
                self.refreshGeneration == currentRefresh, !Task.isCancelled
            else { return }
            self.invalidationTask = nil
            let lists = self.dirtyLists.filter { self.refreshTasks[$0] == nil }
            await withTaskGroup(of: Void.self) { group in
                for list in lists { group.addTask { await self.refreshList(list) } }
            }
        }
    }

    func applyRealtimeEvent(_ event: RealtimeServerEvent, currentUserID: Int32) async {
        pins.applyRealtimeEvent(event)
        switch event {
        case .message(let message):
            let requestGeneration = generation
            let normalized = message.normalizedForRealtime(currentUserID: currentUserID)
            let handled = await outgoingQueue.acceptAcknowledgement(normalized)
            guard generation == requestGeneration else { return }
            if !handled { conversationMessages.apply(.message(normalized)) }
            invalidateChatList()
        case .messageUpdated(let message):
            conversationMessages.apply(
                .messageUpdated(message.normalizedForRealtime(currentUserID: currentUserID)))
            invalidateChatList()
        case .messageDeleted(let message):
            drafts.redactReplyTargets([message.id], chatID: message.chatId)
            conversationMessages.apply(
                .messageDeleted(
                    message.normalizedForRealtime(currentUserID: currentUserID)
                        .redactedForDeletion()))
            invalidateChatList()
        case .reactionUpdated(let payload):
            conversationMessages.apply(
                .reactionUpdated(
                    ReactionUpdatePayload(
                        messageId: payload.messageId, chatId: payload.chatId,
                        reactions: payload.reactions.map {
                            $0.normalizedForRealtime(currentUserID: currentUserID)
                        }
                    )))
        case .messagesBulkDeleted(let payload):
            drafts.redactReplyTargets(Set(payload.messageIds), chatID: payload.chatId)
            conversationMessages.apply(event)
            invalidateChatList()
            scheduleRecovery(chatID: payload.chatId)
        case .threadUpdate:
            conversationMessages.apply(event)
            invalidateChatList()
        case .chatArchiveStateChanged(let payload):
            if let chat = chat(id: payload.chatId) {
                applyArchiveState(
                    to: chat, archived: payload.archived, mutedUntil: payload.mutedUntil)
            }
            invalidateChatList()
        case .threadMembershipChanged:
            invalidateChatList()
        case .friendRequestResolved, .friendshipRemoved:
            invalidateChatList()
        case .stickerPackOrderUpdated(let payload):
            stickers.setPackOrder(payload.order)
        case .pong, .presenceUpdate, .pinAdded, .threadPinAdded,
            .pinRemoved, .threadPinRemoved, .friendRequestReceived:
            break
        case .unknown:
            break
        }
    }

    func updateMessage(_ message: MessageResponse, text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
            text != message.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }
        let requestGeneration = generation
        let optimistic = message.replacingMessageText(text)
        conversationMessages.apply(.messageUpdated(optimistic))
        pins.applyRealtimeEvent(.messageUpdated(optimistic))
        do {
            let updated = try await apiClient.updateMessage(
                chatID: message.chatId, messageID: message.id, body: .init(message: text))
            guard generation == requestGeneration else { return false }
            conversationMessages.apply(.messageUpdated(updated))
            pins.applyRealtimeEvent(.messageUpdated(updated))
            invalidateChatList()
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            conversationMessages.apply(.messageUpdated(message))
            pins.applyRealtimeEvent(.messageUpdated(message))
            if case APIError.invalidToken = error { await onInvalidToken() }
            return false
        }
    }

    func deleteMessage(_ message: MessageResponse) async -> Bool {
        guard !message.isDeleted, message.messageType != .system,
            deletingMessageIDs.insert(message.id).inserted
        else { return false }
        let requestGeneration = generation
        defer { if generation == requestGeneration { deletingMessageIDs.remove(message.id) } }
        do {
            try await apiClient.deleteMessage(chatID: message.chatId, messageID: message.id)
            guard generation == requestGeneration else { return false }
            // Commit redaction only after server acceptance: deleted IDs are
            // tombstoned throughout the shared cache and cannot safely roll back.
            drafts.redactReplyTargets([message.id], chatID: message.chatId)
            conversationMessages.apply(.messageDeleted(message.redactedForDeletion()))
            invalidateChatList()
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            if case APIError.invalidToken = error { await onInvalidToken() }
            return false
        }
    }

    func registerTimeline(_ model: ConversationTimelineModel) {
        timelines[ObjectIdentifier(model)] = WeakTimeline(value: model)
        updateReadState(for: model)
    }

    func unregisterTimeline(_ model: ConversationTimelineModel) {
        timelines.removeValue(forKey: ObjectIdentifier(model))
    }

    private func updateReadState(for model: ConversationTimelineModel) {
        if let threadID = model.threadID,
            let thread = thread(chatID: model.chatID, threadID: threadID)
        {
            model.updateReadState(
                unreadCount: thread.unreadCount, lastReadMessageID: thread.lastReadMessageId)
        } else if model.threadID == nil, let chat = chat(id: model.chatID) {
            model.updateReadState(
                unreadCount: chat.unreadCount, lastReadMessageID: chat.lastReadMessageId)
        }
    }

    private func updateTimelineReadStates() {
        for model in visibleTimelines() { updateReadState(for: model) }
    }

    func reconcileVisibleTimelines() async {
        let models = visibleTimelines()
        await withTaskGroup(of: Void.self) { group in
            let activeChatIDs = Set(models.filter { $0.threadID == nil }.map(\.chatID))
            group.addTask { await self.pins.reconcileAfterReconnect(activeChatIDs: activeChatIDs) }
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
                if self.generation == requestGeneration
                    && self.recoveryGeneration == currentRecovery
                {
                    self.recoveryTasks[chatID] = nil
                }
            }
            repeat {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard self.generation == requestGeneration,
                    self.recoveryGeneration == currentRecovery
                else { return }
                self.recoveryDirty.remove(chatID)
                let models = self.visibleTimelines().filter { $0.chatID == chatID }
                await withTaskGroup(of: Void.self) { group in
                    for model in models { group.addTask { await model.reconcileAfterReconnect() } }
                }
            } while !Task.isCancelled && self.recoveryDirty.contains(chatID)
        }
    }

    func groupInfo(chatID: String) async throws -> GroupInfoResponse {
        let requestGeneration = generation
        let response: GroupInfoResponse = try await performGroupRequest(
            generation: requestGeneration
        ) {
            try await apiClient.groupInfo(chatID: chatID)
        }
        guard response.id == chatID else { throw APIError.unexpectedResponse }
        return response
    }

    func groupMembers(chatID: String, query: ListMembersQuery) async throws -> ListMembersResponse {
        let requestGeneration = generation
        return try await performGroupRequest(generation: requestGeneration) {
            try await apiClient.listMembers(chatID: chatID, query: query)
        }
    }

    func updateGroupMemberRole(chatID: String, uid: Int32, role: GroupRole) async throws
        -> MemberResponse
    {
        let requestGeneration = generation
        let member: MemberResponse = try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            return try await self.performGroupRequest(generation: requestGeneration) {
                try await self.apiClient.updateGroupMemberRole(chatID: chatID, uid: uid, role: role)
            }
        }
        guard member.uid == uid else { throw APIError.unexpectedResponse }
        invalidateChatList()
        return member
    }

    func removeGroupMember(chatID: String, uid: Int32) async throws {
        let requestGeneration = generation
        try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            try await self.performGroupRequest(generation: requestGeneration) {
                try await self.apiClient.removeGroupMember(chatID: chatID, uid: uid)
            }
        }
        invalidateChatList()
    }

    func leaveGroup(chatID: String, uid: Int32) async throws {
        let requestGeneration = generation
        try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            try await self.performGroupRequest(generation: requestGeneration) {
                try await self.apiClient.removeGroupMember(chatID: chatID, uid: uid)
            }
        }
        guard generation == requestGeneration else { throw CancellationError() }
        removeGroupFromLists(chatID: chatID)
    }

    func muteGroup(chatID: String, durationSeconds: Int?) async throws -> Date {
        let requestGeneration = generation
        let mutedUntil: Date = try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            return try await self.performGroupRequest(generation: requestGeneration) {
                try await self.apiClient.muteChat(chatID: chatID, durationSeconds: durationSeconds)
                    .mutedUntil
            }
        }
        guard generation == requestGeneration else { throw CancellationError() }
        if let chat = chat(id: chatID) {
            applyArchiveState(to: chat, archived: chat.archived, mutedUntil: mutedUntil)
        }
        invalidateChatList()
        return mutedUntil
    }

    func unmuteGroup(chatID: String) async throws {
        let requestGeneration = generation
        try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            try await self.performGroupRequest(generation: requestGeneration) {
                try await self.apiClient.unmuteChat(chatID: chatID)
            }
        }
        guard generation == requestGeneration else { throw CancellationError() }
        if let chat = chat(id: chatID) {
            // DELETE /mute also unarchives the chat.
            applyArchiveState(to: chat, archived: false, mutedUntil: nil)
        }
        invalidateChatList()
    }

    func searchMembers(chatID: String, query: ListMembersQuery) async throws -> [MemberResponse] {
        let response = try await groupMembers(chatID: chatID, query: query)
        return response.members
    }

    private func removeGroupFromLists(chatID: String) {
        state.chats.removeAll { $0.id == chatID }
        state.archivedChats.removeAll { $0.id == chatID }
        state.threads.removeAll { $0.chatId == chatID }
        state.archivedThreads.removeAll { $0.chatId == chatID }
        recoveryTasks.removeValue(forKey: chatID)?.cancel()
        recoveryDirty.remove(chatID)
        // Fences in-flight snapshots before the next refresh can observe the leave.
        invalidateChatList()
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery = .init()) async throws
        -> ListMessagesResponse
    {
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
                response = try await apiClient.markThreadRead(
                    chatID: chatID, threadID: threadID, messageID: messageID)
            } else {
                response = try await apiClient.markChatRead(chatID: chatID, messageID: messageID)
            }
            guard generation == requestGeneration else { throw CancellationError() }
            applyReadState(response, chatID: chatID, threadID: threadID)
            if let lastReadMessageID = response.lastReadMessageId {
                onNotificationRead?(.init(chatID: chatID, threadID: threadID), lastReadMessageID)
            }
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
        }
    }

    private func applyReadState(_ response: ReadStateResponse, chatID: String, threadID: String?) {
        listStateRevision += 1
        if let threadID, let thread = thread(chatID: chatID, threadID: threadID) {
            install(
                ThreadListItem(
                    chatId: thread.chatId, chatName: thread.chatName, chatAvatar: thread.chatAvatar,
                    threadRootMessage: thread.threadRootMessage, participants: thread.participants,
                    lastReply: thread.lastReply, replyCount: thread.replyCount,
                    lastReplyAt: thread.lastReplyAt,
                    unreadCount: response.unreadCount,
                    lastReadMessageId: response.lastReadMessageId,
                    subscribedAt: thread.subscribedAt, archived: thread.archived))
        } else if threadID == nil, let chat = chat(id: chatID) {
            install(
                ChatListItem(
                    id: chat.id, name: chat.name, avatar: chat.avatar,
                    lastMessageAt: chat.lastMessageAt,
                    unreadCount: response.unreadCount,
                    lastReadMessageId: response.lastReadMessageId,
                    lastMessage: chat.lastMessage, mutedUntil: chat.mutedUntil,
                    archived: chat.archived,
                    kind: chat.kind, peer: chat.peer))
        }
        // A notification or new thread can be open without an active-list row.
        for model in visibleTimelines() where model.chatID == chatID && model.threadID == threadID {
            model.updateReadState(
                unreadCount: response.unreadCount, lastReadMessageID: response.lastReadMessageId)
        }
    }

    func cancelRealtimeRecovery() {
        pins.cancelLoads()
        refreshGeneration += 1
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        dirtyLists.removeAll()
        for list in ListKind.allCases {
            state[keyPath: list.refreshing] = false
            if state[keyPath: list.phase] == .loading { state[keyPath: list.phase] = .idle }
        }
        invalidationTask?.cancel()
        invalidationTask = nil
        recoveryGeneration += 1
        recoveryDirty.removeAll()
        for task in recoveryTasks.values { task.cancel() }
        recoveryTasks.removeAll()
    }

    func reset() {
        generation += 1
        cancelQueuedGroupMutations()
        pendingListActions.removeAll()
        deletingMessageIDs.removeAll()
        listActionError = nil
        drafts.reset()
        outgoingRevisions.removeAll()
        cancelRealtimeRecovery()
        reactions.reset()
        pins.reset()
        stickers.reset()
        conversationMessages.reset()
        state = ChatState()
    }
}
