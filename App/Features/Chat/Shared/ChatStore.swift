import ChahuaAPI
import Combine
import Foundation
import os

@MainActor
enum ChatListLoadPhase: Equatable {
    case idle, loading, loaded, failed
}

struct ChatState: Equatable {
    var realtimeStatus: RealtimeConnectionStatus = .idle
    var userPresence: [Int32: UserPresenceResponse] = [:]
    var groupPresence: [String: GroupPresenceResponse] = [:]
    var conversationUnreadSummaries: [ConversationUnreadSummary] = []
    var appBadgeCount: Int64?
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

extension ChatState {
    /// Uses the server's app-icon snapshot; a loaded-row total is only a fallback
    /// before the first authorized websocket publication.
    func unreadBadgeCount(excludingChatID: String? = nil, now: Date = Date()) -> Int {
        var total = appBadgeCount ?? 0
        var excluded: Int64 = 0
        for chat in chats where !chat.archived && (chat.mutedUntil.map { $0 <= now } ?? true) {
            let count = max(0, min(Int64(UInt32.max), chat.unreadCount))
            if appBadgeCount == nil { total = min(Int64(UInt32.max), total + count) }
            if chat.id == excludingChatID { excluded = count }
        }
        return Int(max(0, min(Int64(UInt32.max), total - max(0, excluded))))
    }
}

@MainActor
final class ChatStore: ObservableObject {
    private static let logger = Logger(subsystem: "app.chahua.chat", category: "conversations")
    @Published private(set) var state = ChatState()
    // Viewport consumers change the transport watch, not visible UI state.
    // Publishing these through ObservableObject invalidates the list that owns
    // the consumers, reconfiguring every hosted row as avatars mount/unmount.
    private(set) var presenceScope = PresenceScope()
    let presenceScopeChanges = PassthroughSubject<Void, Never>()
    private var presenceConsumers: [UUID: PresenceScope] = [:]
    private var presenceRequestID: UInt64?
    static let unreadSummaryViews = ConversationTabBadges.unreadViews
    private static let unreadSummaryKeys = Set(unreadSummaryViews.map(\.key))
    @Published private(set) var conversationStateScope: [ConversationRef] = []
    let conversationWatchInvalidations = PassthroughSubject<Void, Never>()
    private var conversationConsumers: [UUID: [ConversationRef]] = [:]
    private var unreadRequestID: UInt32?
    private var unreadFullRequestID: UInt32?
    private var statesRequestID: UInt32?
    private var statesFullRequestID: UInt32?
    private var watchedConversations = Set<ConversationKey>()
    private var readyConversations = Set<ConversationKey>()
    private var conversationReadStates: [ConversationKey: ReadStateResponse] = [:]
    private var localStateWrites: [ConversationKey: Int] = [:]
    private var membershipStates: [ConversationKey: ThreadSubscriptionStatus] = [:]
    private var membershipRevision = 0
    private var rowRevisions: [ConversationKey: Int] = [:]
    private var rowTasks: [ConversationKey: Task<Void, Never>] = [:]
    private var dirtyRows = Set<ConversationKey>()
    private var stateFallbackTask: Task<Void, Never>?
    private var stateFallbackGeneration = 0
    private var fallbackKeys = Set<ConversationKey>()
    @Published var currentUserProfile: MeResponse? {
        didSet {
            stickers.setAccount(currentUserProfile?.uid)
            stickers.setPackOrder(currentUserProfile?.stickerPackOrder ?? [])
            guard currentUserProfile != oldValue else { return }
            // Pending rows carry the sender captured in their projection.
            for key in outgoingQueue.snapshots.keys
            where !outgoingQueue.pendingMessages(chatID: key.chatID, threadID: key.threadID).isEmpty
            {
                conversationMessages.replacePending(
                    chatID: key.chatID, threadID: key.threadID,
                    with: pendingProjection(chatID: key.chatID, threadID: key.threadID))
            }
        }
    }
    @Published private(set) var pendingListActions = [ConversationKey: ConversationListAction]()
    @Published var listActionError: String?
    @Published private(set) var deletingMessageIDs = Set<MessageID>()
    let conversationMessages = ConversationMessageStore()
    let chatAccessInvalidations = PassthroughSubject<String, Never>()
    let outgoingQueue: OutgoingMessageQueue
    let reactions: MessageReactionController
    let pins: ChatPinController
    let drafts: ChatDraftStore
    let stickers: StickerLibrary
    var onNotificationRead: ((ConversationKey, MessageID) -> Void)?
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
    private var foregroundActive = true
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
            receivePreview(message, isNew: true)
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
                sender: currentUserProfile.flatMap {
                    $0.uid == message.senderID ? $0.asSender : nil
                },
                state: state, replyToMessage: message.replyToMessage,
                attachments: message.attachments, dispatchClaimed: message.dispatchClaimed,
                editRevision: message.editRevision, sticker: message.sticker,
                forwardRequest: message.forwardRequest
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
        foregroundActive = active
        if !active { clearPresence() }
        outgoingQueue.requestForegroundActive(active)
        if !active {
            drafts.scheduleBackgroundFlush()
            stateFallbackTask?.cancel()
            stateFallbackGeneration += 1
            stateFallbackTask = nil
            fallbackKeys.removeAll()
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
                for chat in chats {
                    conversationReadStates[.init(chatID: chat.id)] = .init(
                        lastReadMessageId: chat.lastReadMessageId, unreadCount: chat.unreadCount,
                        unreadMentions: chat.unreadMentions, unreadReactions: chat.unreadReactions)
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
                let keys = Set(threads.lazy.map(\.conversationKey))
                if list.archived {
                    state.threads.removeAll { keys.contains($0.conversationKey) }
                    state.archivedThreads = threads
                } else {
                    state.archivedThreads.removeAll { keys.contains($0.conversationKey) }
                    state.threads = threads
                }
                for thread in threads {
                    conversationReadStates[thread.conversationKey] = .init(
                        lastReadMessageId: thread.lastReadMessageId,
                        unreadCount: thread.unreadCount,
                        unreadMentions: thread.unreadMentions,
                        unreadReactions: thread.unreadReactions)
                    cacheMembership(
                        .init(subscribed: true, archived: thread.archived),
                        key: thread.conversationKey)
                }
            }
            updateTimelineReadStates()
            fallbackConversationStates()
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
                if seen.insert(thread.conversationKey).inserted { threads.append(thread) }
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
            listActionError = AppLanguage.localized(
                "Couldn’t update conversation. Please try again.")
            if case APIError.invalidToken = error { await onInvalidToken() }
        }
    }

    private func performListActionRequest(
        _ action: ConversationListAction, conversation: ConversationKey,
        generation requestGeneration: Int
    ) async {
        beginLocalStateWrite(conversation)
        defer { finishLocalStateWrite(conversation, generation: requestGeneration) }
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
                        thread(
                            chatID: original.chatId,
                            threadID: original.threadRootMessage.id.description)
                        ?? original
                    install(latest.withArchived(archived))
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
            listStateRevision += 1
            if conversation.threadID != nil, action == .archive || action == .unarchive {
                applyMembership(
                    .init(subscribed: true, archived: action == .archive), key: conversation)
            }
        } catch {
            guard generation == requestGeneration, !(error is CancellationError), !Task.isCancelled
            else { return }
            listActionError = AppLanguage.localized(
                "Couldn’t update conversation. Please try again.")
            // markRead owns its invalid-token handling, including notification cursors.
            if action != .markRead, case APIError.invalidToken = error { await onInvalidToken() }
        }
    }

    private func chat(id: String) -> ChatListItem? {
        state.chats.first { $0.id == id } ?? state.archivedChats.first { $0.id == id }
    }

    private func thread(chatID: String, threadID: String) -> ThreadListItem? {
        state.threads.first {
            $0.chatId == chatID && $0.threadRootMessage.id.description == threadID
        }
            ?? state.archivedThreads.first {
                $0.chatId == chatID && $0.threadRootMessage.id.description == threadID
            }
    }

    /// Legacy events without an absolute membership status require an HTTP reread.
    let threadSubscriptionInvalidations = PassthroughSubject<ConversationKey, Never>()
    let threadSubscriptionChanges =
        PassthroughSubject<(key: ConversationKey, status: ThreadSubscriptionStatus), Never>()

    private func cacheMembership(_ status: ThreadSubscriptionStatus, key: ConversationKey) {
        guard membershipStates[key] != status else { return }
        membershipStates[key] = status
        membershipRevision += 1
        threadSubscriptionChanges.send((key: key, status: status))
    }

    private func applyMembership(_ status: ThreadSubscriptionStatus, key: ConversationKey) {
        guard membershipStates[key] != status else { return }
        cacheMembership(status, key: key)
        listStateRevision += 1
        rowRevisions[key, default: 0] += 1
        if !status.subscribed {
            state.threads.removeAll { $0.conversationKey == key }
            state.archivedThreads.removeAll { $0.conversationKey == key }
        } else if let threadID = key.threadID,
            let current = thread(chatID: key.chatID, threadID: threadID)
        {
            install(current.withArchived(status.archived))
        } else {
            reconcileRow(key)
        }
    }

    func threadSubscriptionStatus(chatID: String, threadID: String) async throws
        -> ThreadSubscriptionStatus
    {
        try Task.checkCancellation()
        let requestGeneration = generation
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        if let cached = membershipStates[key] { return cached }
        let revision = membershipRevision
        do {
            let status = try await apiClient.threadSubscriptionStatus(
                chatID: chatID, threadID: threadID)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            if membershipRevision != revision {
                if let current = membershipStates[key] { return current }
                throw CancellationError()
            }
            cacheMembership(status, key: key)
            return status
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
        }
    }

    /// Applies a thread-detail subscription change and returns the resulting state.
    ///
    /// Serialized with list swipe actions for the same chat; thread lists move only
    /// after server acceptance; unknown rows are reconciled by their root identifier.
    func changeThreadSubscription(
        _ change: ThreadSubscriptionChange, chatID: String, threadID: String
    ) async throws -> ThreadSubscriptionStatus {
        let requestGeneration = generation
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        beginLocalStateWrite(key)
        defer { finishLocalStateWrite(key, generation: requestGeneration) }
        let status: ThreadSubscriptionStatus = try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            do {
                switch change {
                case .subscribe:
                    try await self.apiClient.subscribeThread(chatID: chatID, threadID: threadID)
                    return ThreadSubscriptionStatus(subscribed: true, archived: false)
                case .archive:
                    try await self.apiClient.archiveThread(chatID: chatID, threadID: threadID)
                    return ThreadSubscriptionStatus(subscribed: true, archived: true)
                case .unarchive:
                    try await self.apiClient.unarchiveThread(chatID: chatID, threadID: threadID)
                    return ThreadSubscriptionStatus(subscribed: true, archived: false)
                }
            } catch {
                guard self.generation == requestGeneration else { throw CancellationError() }
                if case APIError.invalidToken = error { await self.onInvalidToken() }
                throw error
            }
        }
        guard generation == requestGeneration else { throw CancellationError() }
        applyMembership(status, key: key)
        return status
    }

    private func install(_ chat: ChatListItem) {
        conversationReadStates[.init(chatID: chat.id)] = .init(
            lastReadMessageId: chat.lastReadMessageId, unreadCount: chat.unreadCount,
            unreadMentions: chat.unreadMentions, unreadReactions: chat.unreadReactions)
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
        conversationReadStates[thread.conversationKey] = .init(
            lastReadMessageId: thread.lastReadMessageId, unreadCount: thread.unreadCount,
            unreadMentions: thread.unreadMentions, unreadReactions: thread.unreadReactions)
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
        cacheMembership(
            .init(subscribed: true, archived: thread.archived), key: thread.conversationKey)
    }

    private func applyArchiveState(to chat: ChatListItem, archived: Bool, mutedUntil: Date?) {
        install(
            ChatListItem(
                id: chat.id, name: chat.name, avatar: chat.avatar,
                lastMessageAt: chat.lastMessageAt,
                unreadCount: chat.unreadCount,
                unreadMentions: chat.unreadMentions, unreadReactions: chat.unreadReactions,
                lastReadMessageId: chat.lastReadMessageId,
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

    /// Resolves only a missing thread root, preserving the session fence used by other reads.
    func threadRoot(for key: ConversationKey) async throws -> MessageResponse {
        guard let threadID = key.threadID, let messageID = MessageID(threadID) else {
            throw APIError.unexpectedResponse
        }
        let requestGeneration = generation
        let root = try await performGroupRequest(generation: requestGeneration) {
            try await apiClient.getMessage(chatID: key.chatID, messageID: messageID)
        }
        guard root.chatId == key.chatID, root.id == messageID, root.replyRootId == nil else {
            throw APIError.unexpectedResponse
        }
        return root
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
                unreadMentions: cached?.unreadMentions ?? 0,
                unreadReactions: cached?.unreadReactions ?? 0,
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

    /// Identifier-filtered reads reconcile only rows whose membership/preview is unknown.
    private func reconcileRow(_ key: ConversationKey) {
        dirtyRows.insert(key)
        rowRevisions[key, default: 0] += 1
        listStateRevision += 1
        guard rowTasks[key] == nil else { return }
        let requestGeneration = generation
        let currentRefresh = refreshGeneration
        rowTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration, refreshGeneration == currentRefresh {
                    rowTasks[key] = nil
                }
            }
            repeat {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard generation == requestGeneration, refreshGeneration == currentRefresh else {
                    return
                }
                guard localStateWrites[key] == nil else { return }
                dirtyRows.remove(key)
                let revision = rowRevisions[key, default: 0]
                do {
                    if let threadID = key.threadID, let rootID = MessageID(threadID) {
                        let preferred =
                            membershipStates[key]?.archived
                            ?? thread(chatID: key.chatID, threadID: threadID)?.archived ?? false
                        var found: ThreadListItem?
                        for archived in [preferred, !preferred] {
                            let response = try await apiClient.listThreads(
                                query: .init(archived: archived, rootId: rootID))
                            try Task.checkCancellation()
                            found = response.threads.first { $0.conversationKey == key }
                            if found != nil { break }
                        }
                        guard generation == requestGeneration, refreshGeneration == currentRefresh
                        else { return }
                        if rowRevisions[key, default: 0] == revision, localStateWrites[key] == nil {
                            if let found {
                                install(found)
                            } else {
                                state.threads.removeAll { $0.conversationKey == key }
                                state.archivedThreads.removeAll { $0.conversationKey == key }
                            }
                        } else {
                            dirtyRows.insert(key)
                        }
                    } else {
                        let preferred = chat(id: key.chatID)?.archived ?? false
                        var found: ChatListItem?
                        for archived in [preferred, !preferred] {
                            let response = try await apiClient.listChats(
                                query: .init(archived: archived, chatId: key.chatID))
                            try Task.checkCancellation()
                            found = response.chats.first { $0.id == key.chatID }
                            if found != nil { break }
                        }
                        guard generation == requestGeneration, refreshGeneration == currentRefresh
                        else { return }
                        if rowRevisions[key, default: 0] == revision, localStateWrites[key] == nil {
                            if let found {
                                install(found)
                            } else {
                                chatAccessInvalidations.send(key.chatID)
                                state.chats.removeAll { $0.id == key.chatID }
                                state.archivedChats.removeAll { $0.id == key.chatID }
                            }
                        } else {
                            dirtyRows.insert(key)
                        }
                    }
                    updateTimelineReadStates()
                } catch {
                    guard generation == requestGeneration, refreshGeneration == currentRefresh,
                        !Task.isCancelled
                    else { return }
                    if case APIError.invalidToken = error { await onInvalidToken() }
                }
            } while dirtyRows.contains(key) && !Task.isCancelled
        }
    }

    private func receivePreview(_ message: MessageResponse, isNew: Bool) {
        let key = ConversationKey(
            chatID: message.chatId, threadID: message.replyRootId?.description)
        rowRevisions[key, default: 0] += 1
        listStateRevision += 1
        if let rootID = key.threadID {
            if let current = thread(chatID: key.chatID, threadID: rootID) {
                if current.lastReply?.id == message.id
                    || (isNew && (current.lastReply.map { $0.id < message.id } ?? true))
                {
                    install(
                        current.withActivity(
                            lastReply: message.replyPreview, replyCount: current.replyCount,
                            lastReplyAt: message.createdAt))
                }
            } else if isNew {
                reconcileRow(key)
            }
        } else {
            if let current = chat(id: key.chatID) {
                if current.lastMessage?.id == message.id
                    || (isNew && (current.lastMessage.map { $0.id < message.id } ?? true))
                {
                    install(current.withPreview(message.replyPreview))
                }
            } else if isNew {
                reconcileRow(key)
            }
            for item in state.threads + state.archivedThreads
            where item.chatId == message.chatId && item.threadRootMessage.id == message.id {
                install(item.withActivity(root: message.replyPreview))
            }
        }
        if !conversationStateReady(chatID: key.chatID, threadID: key.threadID) {
            fallbackConversationStates(key)
        }
    }

    private func invalidateChatList() {
        // Full calibration is reserved for reconnect and changes lacking row identifiers.
        listStateRevision += 1
        invalidateConversationWatches()
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
            receivePreview(normalized, isNew: true)
        case .messageUpdated(let message):
            conversationMessages.apply(
                .messageUpdated(message.normalizedForRealtime(currentUserID: currentUserID)))
            receivePreview(
                message.normalizedForRealtime(currentUserID: currentUserID), isNew: false)
            if !conversationStateReady(
                chatID: message.chatId, threadID: message.replyRootId?.description)
            {
                reconcileRow(
                    .init(chatID: message.chatId, threadID: message.replyRootId?.description))
            }
            refreshVisibleActivity(
                chatID: message.chatId, threadID: message.replyRootId?.description,
                mentions: true, reactions: false)
        case .messageDeleted(let message):
            drafts.redactReplyTargets([message.id], chatID: message.chatId)
            conversationMessages.apply(
                .messageDeleted(
                    message.normalizedForRealtime(currentUserID: currentUserID)
                        .redactedForDeletion()))
            receivePreview(message.redactedForDeletion(), isNew: false)
            reconcileRow(.init(chatID: message.chatId, threadID: message.replyRootId?.description))
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
            let ids = Set(payload.messageIds)
            if let current = chat(id: payload.chatId), let preview = current.lastMessage,
                ids.contains(preview.id)
            {
                install(current.withPreview(preview.redactedForDeletion()))
            }
            reconcileRow(.init(chatID: payload.chatId))
            for item in state.threads + state.archivedThreads where item.chatId == payload.chatId {
                let root =
                    ids.contains(item.threadRootMessage.id)
                    ? item.threadRootMessage.redactedForDeletion() : item.threadRootMessage
                let reply = item.lastReply.map {
                    ids.contains($0.id) ? $0.redactedForDeletion() : $0
                }
                install(item.withActivity(root: root, lastReply: reply))
                reconcileRow(item.conversationKey)
            }
            scheduleRecovery(chatID: payload.chatId)
        case .threadUpdate(let payload):
            conversationMessages.apply(event)
            let key = ConversationKey(chatID: payload.chatId, threadID: payload.threadRootId)
            rowRevisions[key, default: 0] += 1
            listStateRevision += 1
            if let current = thread(chatID: key.chatID, threadID: payload.threadRootId) {
                install(
                    current.withActivity(
                        replyCount: payload.replyCount, lastReplyAt: payload.lastReplyAt))
            } else {
                reconcileRow(key)
            }
            if !conversationStateReady(chatID: key.chatID, threadID: key.threadID) {
                fallbackConversationStates(key)
            }
        case .chatArchiveStateChanged(let payload):
            if let chat = chat(id: payload.chatId) {
                applyArchiveState(
                    to: chat, archived: payload.archived, mutedUntil: payload.mutedUntil)
            }
            listStateRevision += 1
            rowRevisions[.init(chatID: payload.chatId), default: 0] += 1
            if chat(id: payload.chatId) == nil { reconcileRow(.init(chatID: payload.chatId)) }
        case .threadMembershipChanged(let payload):
            let key = ConversationKey(chatID: payload.chatId, threadID: payload.threadRootId)
            if let status = payload.status {
                applyMembership(status, key: key)
            } else {
                membershipStates.removeValue(forKey: key)
                membershipRevision += 1
                threadSubscriptionInvalidations.send(key)
                reconcileRow(key)
            }
        case .notification(let payload):
            if !conversationStateReady(
                chatID: payload.chatId, threadID: payload.threadRootId?.description)
            {
                fallbackConversationStates(
                    .init(chatID: payload.chatId, threadID: payload.threadRootId?.description))
            }
            refreshVisibleActivity(
                chatID: payload.chatId, threadID: payload.threadRootId?.description,
                mentions: payload.notificationType != .reaction,
                reactions: payload.notificationType == .reaction)
        case .readReceiptChanged(let payload):
            for model in visibleTimelines() where model.chatID == payload.chatId {
                model.readReceiptChanged(payload)
            }
        case .friendRequestResolved, .friendshipRemoved:
            invalidateChatList()
            invalidateReadReceipts()
        case .stickerPackOrderUpdated(let payload):
            stickers.setPackOrder(payload.order)
        case .conversationUnread(let payload):
            acceptUnread(payload)
        case .conversationUnreadError(let payload):
            guard payload.requestId == unreadRequestID else { return }
            unreadFullRequestID = nil
        case .conversationStates(let payload):
            acceptConversationStates(payload)
        case .conversationStatesError(let payload):
            guard payload.requestId == statesRequestID else { return }
            statesFullRequestID = nil
            fallbackConversationStates()
        case .presenceSnapshot(let snapshot):
            guard let presenceRequestID, snapshot.requestId == presenceRequestID,
                state.realtimeStatus == .connected
            else { return }
            // Snapshots are absolute: missing/unauthorized entities must not retain
            // a previous online dot or member count.
            var updated = state
            updated.userPresence.removeAll(keepingCapacity: true)
            updated.groupPresence.removeAll(keepingCapacity: true)
            for user in snapshot.users { updated.userPresence[user.uid] = user }
            for group in snapshot.groups { updated.groupPresence[group.chatId] = group }
            state = updated
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
            receivePreview(updated, isNew: false)
            if !conversationStateReady(
                chatID: updated.chatId, threadID: updated.replyRootId?.description)
            {
                reconcileRow(
                    .init(chatID: updated.chatId, threadID: updated.replyRootId?.description))
            }
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
            receivePreview(message.redactedForDeletion(), isNew: false)
            reconcileRow(.init(chatID: message.chatId, threadID: message.replyRootId?.description))
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            if case APIError.invalidToken = error { await onInvalidToken() }
            return false
        }
    }

    func setRealtimeStatus(_ status: RealtimeConnectionStatus) {
        guard state.realtimeStatus != status else { return }
        state.realtimeStatus = status
        if status != .connected {
            clearPresence()
            clearConversationWatches()
            membershipStates.removeAll()
            membershipRevision += 1
        }
        for model in visibleTimelines() { model.setRealtimeStatus(status) }
    }

    func setPresenceScope(_ scope: PresenceScope, for id: UUID) {
        guard presenceConsumers[id] != scope else { return }
        presenceConsumers[id] = scope
        updatePresenceScope()
    }

    func removePresenceScope(for id: UUID) {
        guard presenceConsumers.removeValue(forKey: id) != nil else { return }
        updatePresenceScope()
    }

    private func updatePresenceScope() {
        let scope = PresenceScope.combined(presenceConsumers.values)
        guard scope != presenceScope else { return }
        presenceRequestID = nil
        ScrollPerformanceTrace.event(
            "Presence.ScopeChanged", count: scope.userIDs.count + scope.chatIDs.count)
        presenceScope = scope
        presenceScopeChanges.send(())
    }

    func presenceSettings() async throws -> PresenceSettingsResponse {
        try await performGroupRequest(generation: generation) {
            try await apiClient.presenceSettings()
        }
    }

    func updatePresenceSettings(visibility: PresenceVisibility) async throws
        -> PresenceSettingsResponse
    {
        let requestGeneration = generation
        return try await performGroupRequest(generation: requestGeneration) {
            let settings = try await apiClient.updatePresenceSettings(visibility: visibility)
            guard generation == requestGeneration else { throw CancellationError() }
            // A committed privacy change invalidates cached individual status even
            // if its settings view has since been dismissed or cancelled.
            invalidateIndividualPresence()
            return settings
        }
    }

    func readReceipt(chatID: String, threadID: MessageID?) async throws -> ReadReceiptResponse {
        try await performGroupRequest(generation: generation) {
            try await apiClient.readReceipt(chatID: chatID, threadID: threadID)
        }
    }

    func readReceiptSettings() async throws -> ReadReceiptSettingsResponse {
        try await performGroupRequest(generation: generation) {
            try await apiClient.readReceiptSettings()
        }
    }

    func updateReadReceiptSettings(visibility: ReadReceiptVisibility) async throws
        -> ReadReceiptSettingsResponse
    {
        let requestGeneration = generation
        return try await performGroupRequest(generation: requestGeneration) {
            let settings = try await apiClient.updateReadReceiptSettings(visibility: visibility)
            guard generation == requestGeneration else { throw CancellationError() }
            // Invalidation belongs to the committed write, not the settings view's lifetime.
            invalidateReadReceipts()
            return settings
        }
    }

    func friendReadReceiptSettings(peerUID: Int32) async throws
        -> FriendReadReceiptSettingsResponse
    {
        try await performGroupRequest(generation: generation) {
            try await apiClient.friendReadReceiptSettings(peerUID: peerUID)
        }
    }

    func updateFriendReadReceiptSettings(peerUID: Int32, override: FriendReadReceiptOverride)
        async throws -> FriendReadReceiptSettingsResponse
    {
        let requestGeneration = generation
        return try await performGroupRequest(generation: requestGeneration) {
            let settings = try await apiClient.updateFriendReadReceiptSettings(
                peerUID: peerUID, override: override)
            guard generation == requestGeneration else { throw CancellationError() }
            invalidateReadReceipts(peerUID: peerUID)
            return settings
        }
    }

    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse {
        let response = try await performGroupRequest(generation: generation) {
            try await apiClient.friendRelationship(peerUID: peerUID)
        }
        guard response.peerUid == peerUID else { throw APIError.unexpectedResponse }
        return response
    }

    let presencePrivacyInvalidations = PassthroughSubject<Void, Never>()

    private func invalidateIndividualPresence() {
        // Fence old snapshots immediately; the new watch keeps group counts visible.
        presenceRequestID = nil
        if !state.userPresence.isEmpty {
            var updated = state
            updated.userPresence.removeAll()
            state = updated
        }
        presencePrivacyInvalidations.send(())
    }

    /// Prune at coalesced watch publication, not during transient SwiftUI
    /// unmount/remount callbacks. Overlapping status stays visible while loading.
    func beginPresenceRequest(_ requestID: UInt64) {
        let scope = presenceScope
        presenceRequestID = requestID
        // A watch refresh is not an offline transition. Retain overlapping IDs
        // while loading, but remove data whose UI consumer left the scope.
        let users = Set(scope.userIDs)
        let groups = Set(scope.chatIDs)
        var updated = state
        for uid in state.userPresence.keys where !users.contains(uid) {
            updated.userPresence.removeValue(forKey: uid)
        }
        for chatID in state.groupPresence.keys where !groups.contains(chatID) {
            updated.groupPresence.removeValue(forKey: chatID)
        }
        if updated.userPresence.count != state.userPresence.count
            || updated.groupPresence.count != state.groupPresence.count
        {
            state = updated
        }
    }

    func isCurrentPresenceRequest(_ requestID: UInt64) -> Bool {
        presenceRequestID == requestID
    }

    func clearPresence() {
        presenceRequestID = nil
        guard !state.userPresence.isEmpty || !state.groupPresence.isEmpty else { return }
        var updated = state
        updated.userPresence.removeAll()
        updated.groupPresence.removeAll()
        state = updated
    }

    func registerTimeline(_ model: ConversationTimelineModel) {
        timelines[ObjectIdentifier(model)] = WeakTimeline(value: model)
        model.setRealtimeStatus(state.realtimeStatus)
        updateReadState(for: model)
        updateConversationStateScope()
    }

    func unregisterTimeline(_ model: ConversationTimelineModel) {
        timelines.removeValue(forKey: ObjectIdentifier(model))
        updateConversationStateScope()
    }

    /// A committed sharing-policy change revokes cached receipts before refetching.
    func invalidateReadReceipts(peerUID: Int32? = nil) {
        for model in visibleTimelines() {
            // A notification can open a conversation not present in the cached lists.
            if let peerUID, let modelPeerUID = chat(id: model.chatID)?.peer?.uid,
                modelPeerUID != peerUID
            {
                continue
            }
            model.refreshReadReceipt(clear: true)
        }
    }

    private func updateReadState(for model: ConversationTimelineModel) {
        if let cached = conversationReadStates[
            .init(chatID: model.chatID, threadID: model.threadID)]
        {
            model.updateReadState(
                unreadCount: cached.unreadCount, lastReadMessageID: cached.lastReadMessageId)
            model.updateUnreadActivityState(
                unreadMentions: cached.unreadMentions, unreadReactions: cached.unreadReactions)
            return
        }
        if let threadID = model.threadID,
            let thread = thread(chatID: model.chatID, threadID: threadID)
        {
            model.updateReadState(
                unreadCount: thread.unreadCount, lastReadMessageID: thread.lastReadMessageId)
            model.updateUnreadActivityState(
                unreadMentions: thread.unreadMentions, unreadReactions: thread.unreadReactions)
        } else if model.threadID == nil, let chat = chat(id: model.chatID) {
            model.updateReadState(
                unreadCount: chat.unreadCount, lastReadMessageID: chat.lastReadMessageId)
            model.updateUnreadActivityState(
                unreadMentions: chat.unreadMentions, unreadReactions: chat.unreadReactions)
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

    func setConversationStateScope(_ refs: [ConversationRef], for consumer: UUID) {
        guard conversationConsumers[consumer] != refs else { return }
        conversationConsumers[consumer] = refs
        updateConversationStateScope()
    }

    func removeConversationStateScope(for consumer: UUID) {
        guard conversationConsumers.removeValue(forKey: consumer) != nil else { return }
        updateConversationStateScope()
    }

    private func updateConversationStateScope() {
        func ordered(_ refs: [ConversationRef]) -> [ConversationRef] {
            refs.sorted {
                if $0.chatId != $1.chatId { return $0.chatId < $1.chatId }
                return ($0.threadId?.description ?? "") < ($1.threadId?.description ?? "")
            }
        }
        let active = ordered(
            visibleTimelines().map {
                ConversationRef(chatId: $0.chatID, threadId: $0.threadID.flatMap(MessageID.init))
            })
        let lists = ordered(conversationConsumers.values.flatMap { $0 })
        var seen = Set<ConversationKey>()
        let refs = (active + lists).filter {
            seen.insert(ConversationKey(chatID: $0.chatId, threadID: $0.threadId?.description))
                .inserted
        }
        let selected = Array(refs.prefix(512))
        guard selected != conversationStateScope else { return }
        statesRequestID = nil
        statesFullRequestID = nil
        conversationStateScope = selected
        fallbackConversationStates()
    }

    func beginConversationUnreadWatch(requestID: UInt32) {
        unreadRequestID = requestID
        unreadFullRequestID = nil
    }

    func beginConversationStatesWatch(requestID: UInt32) {
        statesRequestID = requestID
        statesFullRequestID = nil
        readyConversations.removeAll()
        watchedConversations = Set(
            conversationStateScope.map {
                ConversationKey(chatID: $0.chatId, threadID: $0.threadId?.description)
            })
    }

    func clearConversationWatches() {
        unreadRequestID = nil
        unreadFullRequestID = nil
        statesRequestID = nil
        statesFullRequestID = nil
        watchedConversations.removeAll()
        readyConversations.removeAll()
    }

    private func invalidateConversationWatches() {
        clearConversationWatches()
        conversationWatchInvalidations.send(())
    }

    func conversationStateReady(chatID: String, threadID: String?) -> Bool {
        state.realtimeStatus == .connected && statesRequestID != nil
            && statesFullRequestID == statesRequestID
            && readyConversations.contains(.init(chatID: chatID, threadID: threadID))
    }

    private func acceptUnread(_ payload: ConversationUnreadPayload) {
        guard state.realtimeStatus == .connected, localStateWrites.isEmpty,
            payload.requestId == unreadRequestID,
            payload.full || unreadFullRequestID == payload.requestId
        else { return }
        if payload.full { unreadFullRequestID = payload.requestId }
        var summaries = payload.full ? [] : state.conversationUnreadSummaries
        for summary in payload.summaries where Self.unreadSummaryKeys.contains(summary.key) {
            if let index = summaries.firstIndex(where: { $0.key == summary.key }) {
                summaries[index] = summary
            } else {
                summaries.append(summary)
            }
        }
        state.conversationUnreadSummaries = summaries
        if payload.full || payload.appBadgeCount != nil {
            state.appBadgeCount = payload.appBadgeCount.map { max(0, $0) }
        }
    }

    private func acceptConversationStates(_ payload: ConversationStatesPayload) {
        guard state.realtimeStatus == .connected, payload.requestId == statesRequestID,
            payload.full || statesFullRequestID == payload.requestId
        else { return }
        if payload.full {
            statesFullRequestID = payload.requestId
            readyConversations.removeAll()
        }
        for value in payload.states {
            let key = ConversationKey(chatID: value.chatId, threadID: value.threadId?.description)
            guard watchedConversations.contains(key), localStateWrites[key] == nil else { continue }
            readyConversations.insert(key)
            rowRevisions[key, default: 0] += 1
            if !value.accessible {
                conversationReadStates.removeValue(forKey: key)
                if key.threadID == nil {
                    state.chats.removeAll { $0.id == key.chatID }
                    state.archivedChats.removeAll { $0.id == key.chatID }
                } else {
                    state.threads.removeAll { $0.conversationKey == key }
                    state.archivedThreads.removeAll { $0.conversationKey == key }
                }
                listStateRevision += 1
            }
            applyReadState(
                .init(
                    lastReadMessageId: value.lastReadMessageId, unreadCount: value.unreadCount,
                    unreadMentions: value.unreadMentions, unreadReactions: value.unreadReactions),
                chatID: key.chatID, threadID: key.threadID)
        }
    }

    func conversationReadState(chatID: String, threadID: String?) async throws -> ReadStateResponse
    {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        if conversationStateReady(chatID: chatID, threadID: threadID),
            let cached = conversationReadStates[key]
        {
            return cached
        }
        let revision = rowRevisions[key, default: 0]
        rowRevisions[key] = revision
        let response = try await performGroupRequest(generation: generation) {
            if let threadID {
                return try await apiClient.threadReadState(chatID: chatID, threadID: threadID)
            }
            return try await apiClient.chatReadState(chatID: chatID)
        }
        guard rowRevisions[key, default: 0] == revision, localStateWrites[key] == nil else {
            if let cached = conversationReadStates[key] { return cached }
            throw CancellationError()
        }
        applyReadState(response, chatID: chatID, threadID: threadID)
        return response
    }

    private func fallbackConversationStates(_ key: ConversationKey? = nil) {
        guard foregroundActive else { return }
        if let key {
            fallbackKeys.insert(key)
        } else {
            fallbackKeys.formUnion(
                conversationStateScope.map {
                    ConversationKey(chatID: $0.chatId, threadID: $0.threadId?.description)
                })
        }
        guard stateFallbackTask == nil, !fallbackKeys.isEmpty else { return }
        let requestGeneration = generation
        let currentRefresh = refreshGeneration
        let currentFallback = stateFallbackGeneration
        stateFallbackTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration, refreshGeneration == currentRefresh,
                    stateFallbackGeneration == currentFallback
                {
                    stateFallbackTask = nil
                }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            while !fallbackKeys.isEmpty {
                let keys = fallbackKeys
                fallbackKeys.removeAll()
                for key in keys {
                    guard generation == requestGeneration, refreshGeneration == currentRefresh,
                        !Task.isCancelled
                    else { return }
                    _ = try? await conversationReadState(chatID: key.chatID, threadID: key.threadID)
                }
            }
        }
    }

    private func beginLocalStateWrite(_ key: ConversationKey) {
        localStateWrites[key, default: 0] += 1
        rowRevisions[key, default: 0] += 1
        listStateRevision += 1
        unreadRequestID = nil
        unreadFullRequestID = nil
    }

    private func finishLocalStateWrite(_ key: ConversationKey, generation requestGeneration: Int) {
        guard generation == requestGeneration else { return }
        if let count = localStateWrites[key], count > 1 {
            localStateWrites[key] = count - 1
        } else {
            localStateWrites.removeValue(forKey: key)
        }
        rowRevisions[key, default: 0] += 1
        invalidateConversationWatches()
        if localStateWrites[key] == nil, dirtyRows.contains(key) { reconcileRow(key) }
    }

    private func refreshVisibleActivity(
        chatID: String, threadID: String?, mentions: Bool = true, reactions: Bool = true
    ) {
        for model in visibleTimelines()
        where model.chatID == chatID && model.threadID == threadID {
            model.refreshUnreadActivity(mentions: mentions, reactions: reactions)
        }
    }

    func unreadMentions(chatID: String, threadID: String?) async throws -> UnreadMentionIDsResponse
    {
        guard foregroundActive else { throw CancellationError() }
        let root = try activityThreadID(threadID)
        return try await performGroupRequest(generation: generation) {
            try await apiClient.unreadMentions(chatID: chatID, threadID: root)
        }
    }

    func unreadReactions(chatID: String, threadID: String?) async throws
        -> UnreadReactionIDsResponse
    {
        guard foregroundActive else { throw CancellationError() }
        let root = try activityThreadID(threadID)
        return try await performGroupRequest(generation: generation) {
            try await apiClient.unreadReactions(chatID: chatID, threadID: root)
        }
    }

    func acknowledgeReactions(chatID: String, threadID: String?, readThrough: String?) async throws
        -> UnreadReactionsAckResponse
    {
        guard foregroundActive else { throw CancellationError() }
        let root = try activityThreadID(threadID)
        let requestGeneration = generation
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        beginLocalStateWrite(key)
        defer { finishLocalStateWrite(key, generation: requestGeneration) }
        let response = try await performGroupRequest(generation: generation) {
            try await apiClient.acknowledgeReactions(
                chatID: chatID, threadID: root, readThrough: readThrough)
        }
        guard foregroundActive else { throw CancellationError() }
        // Reaction acknowledgement never advances the ordinary message read cursor.
        if let threadID, let thread = thread(chatID: chatID, threadID: threadID) {
            applyReadState(
                .init(
                    lastReadMessageId: thread.lastReadMessageId, unreadCount: thread.unreadCount,
                    unreadMentions: thread.unreadMentions, unreadReactions: response.unreadReactions
                ),
                chatID: chatID, threadID: threadID)
        } else if threadID == nil, let chat = chat(id: chatID) {
            applyReadState(
                .init(
                    lastReadMessageId: chat.lastReadMessageId, unreadCount: chat.unreadCount,
                    unreadMentions: chat.unreadMentions, unreadReactions: response.unreadReactions),
                chatID: chatID, threadID: nil)
        } else if let cached = conversationReadStates[key] {
            applyReadState(
                .init(
                    lastReadMessageId: cached.lastReadMessageId, unreadCount: cached.unreadCount,
                    unreadMentions: cached.unreadMentions, unreadReactions: response.unreadReactions
                ),
                chatID: chatID, threadID: threadID)
        }
        return response
    }

    private func activityThreadID(_ threadID: String?) throws -> MessageID? {
        guard let threadID else { return nil }
        guard let root = MessageID(threadID) else { throw APIError.unexpectedResponse }
        return root
    }

    func reactionDetails(chatID: String, messageID: MessageID) async throws
        -> ReactionDetailResponse
    {
        try Task.checkCancellation()
        let requestGeneration = generation
        do {
            let response = try await apiClient.getReactionDetails(
                chatID: chatID, messageID: messageID)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            return response
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
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
        let key = ConversationKey(chatID: chatID)
        beginLocalStateWrite(key)
        defer { finishLocalStateWrite(key, generation: requestGeneration) }
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
        listStateRevision += 1
        return mutedUntil
    }

    func unmuteGroup(chatID: String) async throws {
        let requestGeneration = generation
        let key = ConversationKey(chatID: chatID)
        beginLocalStateWrite(key)
        defer { finishLocalStateWrite(key, generation: requestGeneration) }
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
        listStateRevision += 1
    }

    func searchMembers(chatID: String, query: ListMembersQuery) async throws -> [MemberResponse] {
        let response = try await groupMembers(chatID: chatID, query: query)
        return response.members
    }

    private func removeGroupFromLists(chatID: String) {
        chatAccessInvalidations.send(chatID)
        state.chats.removeAll { $0.id == chatID }
        state.archivedChats.removeAll { $0.id == chatID }
        state.threads.removeAll { $0.chatId == chatID }
        state.archivedThreads.removeAll { $0.chatId == chatID }
        conversationReadStates = conversationReadStates.filter { $0.key.chatID != chatID }
        for key in rowRevisions.keys where key.chatID == chatID {
            rowRevisions[key, default: 0] += 1
        }
        for key in membershipStates.keys where key.chatID == chatID {
            cacheMembership(.init(subscribed: false, archived: false), key: key)
        }
        membershipRevision += 1
        recoveryTasks.removeValue(forKey: chatID)?.cancel()
        recoveryDirty.remove(chatID)
        // Fences in-flight snapshots before the next refresh can observe the leave.
        invalidateChatList()
    }

    func forwardDestinationChats(query: ListChatsQuery) async throws -> ListChatsResponse {
        try await performGroupRequest(generation: generation) {
            try await apiClient.listChats(query: query)
        }
    }

    func forwardDestinationThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse {
        try await performGroupRequest(generation: generation) {
            try await apiClient.listThreads(query: query)
        }
    }

    func forwardSourceMessage(chatID: String, messageID: MessageID) async throws -> MessageResponse
    {
        try await performGroupRequest(generation: generation) {
            try await apiClient.getMessage(chatID: chatID, messageID: messageID)
        }
    }

    func forwardedMessages(chatID: String, messageID: MessageID, bundleID: String? = nil)
        async throws -> ForwardedMessagesResponse
    {
        try await performGroupRequest(generation: generation) {
            try await apiClient.getForwardedMessages(
                chatID: chatID, messageID: messageID, bundleID: bundleID)
        }
    }

    func savedForwardedMessages(savedMessageID: String, bundleID: String? = nil)
        async throws -> ForwardedMessagesResponse
    {
        try await performGroupRequest(generation: generation) {
            try await apiClient.getSavedForwardedMessages(
                savedMessageID: savedMessageID, bundleID: bundleID)
        }
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

    func searchMessages(chatID: String, query: SearchMessagesQuery) async throws
        -> SearchMessagesResponse
    {
        try Task.checkCancellation()
        let requestGeneration = generation
        do {
            let response = try await apiClient.searchMessages(chatID: chatID, query: query)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            return response
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
        }
    }

    func markRead(chatID: String, threadID: String?, messageID: MessageID) async throws {
        try Task.checkCancellation()
        let requestGeneration = generation
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        beginLocalStateWrite(key)
        defer { finishLocalStateWrite(key, generation: requestGeneration) }
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
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        conversationReadStates[key] = response
        rowRevisions[key, default: 0] += 1
        if let threadID, let thread = thread(chatID: chatID, threadID: threadID) {
            install(
                ThreadListItem(
                    chatId: thread.chatId, chatName: thread.chatName, chatAvatar: thread.chatAvatar,
                    threadRootMessage: thread.threadRootMessage, participants: thread.participants,
                    lastReply: thread.lastReply, replyCount: thread.replyCount,
                    lastReplyAt: thread.lastReplyAt,
                    unreadCount: response.unreadCount,
                    unreadMentions: response.unreadMentions,
                    unreadReactions: response.unreadReactions,
                    lastReadMessageId: response.lastReadMessageId,
                    chatKind: thread.chatKind,
                    subscribedAt: thread.subscribedAt, archived: thread.archived))
        } else if threadID == nil, let chat = chat(id: chatID) {
            install(
                ChatListItem(
                    id: chat.id, name: chat.name, avatar: chat.avatar,
                    lastMessageAt: chat.lastMessageAt,
                    unreadCount: response.unreadCount,
                    unreadMentions: response.unreadMentions,
                    unreadReactions: response.unreadReactions,
                    lastReadMessageId: response.lastReadMessageId,
                    lastMessage: chat.lastMessage, mutedUntil: chat.mutedUntil,
                    archived: chat.archived,
                    kind: chat.kind, peer: chat.peer))
        }
        // A notification or new thread can be open without an active-list row.
        for model in visibleTimelines() where model.chatID == chatID && model.threadID == threadID {
            model.updateReadState(
                unreadCount: response.unreadCount, lastReadMessageID: response.lastReadMessageId)
            model.updateUnreadActivityState(
                unreadMentions: response.unreadMentions, unreadReactions: response.unreadReactions)
        }
    }

    func cancelRealtimeRecovery() {
        pins.cancelLoads()
        stateFallbackTask?.cancel()
        stateFallbackTask = nil
        fallbackKeys.removeAll()
        for task in rowTasks.values { task.cancel() }
        rowTasks.removeAll()
        dirtyRows.removeAll()
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
        presenceConsumers.removeAll()
        presenceScope = PresenceScope()
        presenceScopeChanges.send(())
        clearPresence()
        clearConversationWatches()
        conversationConsumers.removeAll()
        conversationStateScope = []
        conversationReadStates.removeAll()
        localStateWrites.removeAll()
        membershipStates.removeAll()
        membershipRevision += 1
        rowRevisions.removeAll()
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
        setRealtimeStatus(.idle)
        state = ChatState()
    }
}

extension ChatListItem {
    fileprivate func withPreview(_ preview: MessagePreview) -> ChatListItem {
        ChatListItem(
            id: id, name: name, avatar: avatar, lastMessageAt: preview.createdAt,
            unreadCount: unreadCount, unreadMentions: unreadMentions,
            unreadReactions: unreadReactions, lastReadMessageId: lastReadMessageId,
            lastMessage: preview, mutedUntil: mutedUntil, archived: archived,
            kind: kind, peer: peer)
    }
}

extension ThreadListItem {
    fileprivate func withActivity(
        root: MessagePreview? = nil, lastReply: MessagePreview? = nil,
        replyCount: Int64? = nil, lastReplyAt: Date? = nil
    ) -> ThreadListItem {
        ThreadListItem(
            chatId: chatId, chatName: chatName, chatAvatar: chatAvatar,
            threadRootMessage: root ?? threadRootMessage, participants: participants,
            lastReply: lastReply ?? self.lastReply, replyCount: replyCount ?? self.replyCount,
            lastReplyAt: lastReplyAt ?? self.lastReplyAt, unreadCount: unreadCount,
            unreadMentions: unreadMentions, unreadReactions: unreadReactions,
            lastReadMessageId: lastReadMessageId, chatKind: chatKind,
            subscribedAt: subscribedAt, archived: archived)
    }
}
