import ChahuaAPI
import Combine
import Foundation
import os

@MainActor
enum ChatListLoadPhase: Equatable {
    case idle, loading, loaded, failed
}

enum ChatListAvailability: Equatable {
    case absent
    case cached(complete: Bool)
    case server(complete: Bool)

    var isComplete: Bool {
        switch self {
        case .absent: false
        case .cached(let complete), .server(let complete): complete
        }
    }
}

struct ChatState: Equatable {
    var realtimeStatus: RealtimeConnectionStatus = .idle
    var userPresence: [Int32: UserPresenceResponse] = [:]
    var groupPresence: [String: GroupPresenceResponse] = [:]
    var conversationUnreadSummaries: [ConversationUnreadSummary] = []
    var appBadgeCount: Int64?
    var mainUnread: MainUnreadSnapshot?
    var notificationDefaults: NotificationSettingsResponse?
    var listAvailability: [CachedListScope: ChatListAvailability] = [:]
    var savedListHasMore = Set<CachedListScope>()
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
    func unreadBadgeCount(now: Date = Date()) -> Int {
        if let appBadgeCount { return Int(max(0, min(Int64(UInt32.max), appBadgeCount))) }
        var total: Int64 = 0
        for chat in chats
        where !chat.archived && !chat.notificationMuted(defaults: notificationDefaults, now: now) {
            let count = max(0, min(Int64(UInt32.max), chat.unreadCount))
            total = min(Int64(UInt32.max), total + count)
        }
        return Int(total)
    }
}

@MainActor
final class ChatStore: ObservableObject {
    private static let logger = Logger(subsystem: "app.chahua.chat", category: "conversations")
    @Published private(set) var state = ChatState()
    @Published private(set) var groupInfoByChatID: [String: GroupInfoResponse] = [:]
    @Published private(set) var memberSpeakingModesByChatID:
        [String: [Int32: MemberSpeakingModeResponse]] = [:]
    @Published private(set) var sessionRevision = 0
    let displayPreferences: ConversationDisplayPreferences
    @Published private(set) var messageUpdateError: String?
    private var groupInfoRevisions: [String: Int] = [:]
    private var groupInfoInvalidations = Set<String>()
    private var groupInfoReadSequences: [String: Int] = [:]
    private var groupSpeakingRevisions: [String: Int] = [:]
    private var memberSpeakingRevisions: [String: [Int32: Int]] = [:]
    private var fullSnapshotRecoveries = Set<String>()
    private var confirmedThreadRoots = Set<ConversationKey>()
    private var membershipPolicies: [String: MembershipMessagePolicy] = [:]
    private var membershipPolicyRevisions: [String: Int] = [:]
    private var membershipSettingsRevision = 0
    private var membershipSettingsWrites = 0
    private var membershipChatSettings: ChatSettings?
    // Viewport consumers change the transport watch, not visible UI state.
    // Publishing these through ObservableObject invalidates the list that owns
    // the consumers, reconfiguring every hosted row as avatars mount/unmount.
    private(set) var presenceScope = PresenceScope()
    let presenceScopeChanges = PassthroughSubject<Void, Never>()
    private var presenceConsumers: [UUID: PresenceScope] = [:]
    private var presenceRequestID: UInt64?
    static let unreadSummaryViews = ConversationTabBadges.unreadViews
    private static let unreadSummaryKeys = Set(unreadSummaryViews.map(\.key))
    /// Main-list eligibility and counting unit come from one authoritative snapshot,
    /// regardless of the route (including Archive) or independently delivered settings.
    func backBadgeCount(excludingChatID chatID: String?) -> Int {
        guard state.realtimeStatus == .connected, let chatID,
            let snapshot = state.mainUnread
        else { return 0 }
        var count: Int64 = 0
        for chat in snapshot.chats where chat.chatId != chatID {
            count += snapshot.showUnreadMessageCount ? max(0, min(1000, chat.unreadCount)) : 1
            if snapshot.showUnreadMessageCount && count >= 1000 { return 1000 }
        }
        return Int(count)
    }

    // Like presence, viewport/read-watch scope changes notify transport without
    // invalidating views observing the shared store.
    private(set) var conversationStateScope: [ConversationRef] = []
    let conversationStateScopeChanges = PassthroughSubject<Void, Never>()
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
    private struct ReadAcknowledgement {
        let token: Int
        let requestedCursor: MessageID
        let resetVersion: Int
        let task: Task<Void, Error>
        var watchedThrough: MessageID?
        var sawWatchedState = false
    }
    private struct ReadFence {
        let cursor: MessageID
        let version: Int
        let watchRequestID: UInt32?
    }
    private var readAcknowledgements: [ConversationKey: ReadAcknowledgement] = [:]
    private var readFences: [ConversationKey: ReadFence] = [:]
    private var readStateVersion = 0
    private var readStateVersions: [ConversationKey: Int] = [:]
    private var readResetVersions: [ConversationKey: Int] = [:]
    private struct AutomaticRead {
        let target: MessageID
        let chatVersion: Int
        let version: Int
        let networkVersion: Int
    }
    private var confirmedReadCursors: [ConversationKey: MessageID] = [:]
    private var pendingReadVersions: [ConversationKey: Int] = [:]
    private var pendingReadChatVersions: [String: Int] = [:]
    private var deniedReadScopes = Set<ConversationKey>()
    private var readNetworkVersion = 0
    private var pendingReadTask: Task<Void, Never>?
    private var pendingReadSweepRequested = false
    private var pendingReadSweepVersion: Int?
    private var pendingReadWakes = Set<ConversationKey>()
    private var membershipStates: [ConversationKey: ThreadSubscriptionStatus] = [:]
    private var membershipRevision = 0
    private var rowRevisions: [ConversationKey: Int] = [:]
    private var rowTasks: [ConversationKey: Task<Void, Never>] = [:]
    private var dirtyRows = Set<ConversationKey>()
    private var stateFallbackTask: Task<Void, Never>?
    private var stateFallbackGeneration = 0
    private var fallbackKeys = Set<ConversationKey>()
    private var readFenceReconciliations = Set<ConversationKey>()
    @Published var currentUserProfile: MeResponse? {
        didSet {
            stickers.setAccount(currentUserProfile?.uid)
            savedMessages.setAccount(currentUserProfile?.uid)
            stickers.setPackOrder(currentUserProfile?.stickerPackOrder ?? [])
            guard currentUserProfile != oldValue else { return }
            if let settings = membershipChatSettings, currentUserProfile != nil,
                currentUserProfile?.showMembershipMessages != settings.showMembershipMessages
                    || currentUserProfile?.showUnreadMessageCount != settings.showUnreadMessageCount
            {
                currentUserProfile = currentUserProfile?.withChatSettings(settings)
            } else if let show = currentUserProfile?.showMembershipMessages {
                acceptChatSettings(
                    .init(
                        showMembershipMessages: show,
                        showUnreadMessageCount: currentUserProfile?.showUnreadMessageCount ?? false)
                )
            }
            if state.notificationDefaults == nil, let profile = currentUserProfile,
                let groups = profile.muteGroupChatsByDefault,
                let direct = profile.muteDirectChatsByDefault
            {
                state.notificationDefaults = .init(
                    muteGroupChatsByDefault: groups, muteDirectChatsByDefault: direct)
            }
            // Pending rows carry the sender captured in their projection.
            for key in outgoingQueue.snapshots.keys {
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
    let historyCache: AccountHistoryCache?
    @Published var messageStorageFull = false
    @Published var isResettingLocalDatabase = false
    @Published var localDatabaseResetFailed = false
    var onResetLocalDatabase: ((Int32) async -> Void)?
    @Published private(set) var savedSendDecisions: [ConversationKey: Bool] = [:]
    private var sendPermissionVersions: [String: Int] = [:]
    private var sendPermissionPeers: [String: Int32] = [:]
    private var peerPermissionVersion = 0
    private var dispatchPermissionChecks = Set<ConversationKey>()
    private var reachabilityObservation: AnyCancellable?
    let listReadReceipts = ConversationListReadReceipts()
    @Published private(set) var pendingListPreviews: [ConversationKey: LocalOutgoingMessage] = [:]
    let reactions: MessageReactionController
    let pins: ChatPinController
    let drafts: ChatDraftStore
    let stickers: StickerLibrary
    let savedMessages: SavedMessageController
    var onNotificationRead: ((ConversationKey, MessageID) -> Void)?
    private var outgoingObservation: AnyCancellable?
    private var storageObservation: AnyCancellable?
    private var outgoingRevisions: [ConversationKey: Int64] = [:]

    private let apiClient: any ChahuaAPIClient
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var generation = 0
    private var listStateRevision = 0
    private var refreshTasks: [ListKind: (task: Task<Void, Never>, ignoresPath: Bool)] = [:]
    private var listHydrationTasks: [ListKind: Task<Void, Never>] = [:]
    private var savedListsRead = Set<ListKind>()
    private var savedListCursors: [ListKind: CachedListPage.Cursor] = [:]
    private var refreshGeneration = 0
    private var invalidationTask: Task<Void, Never>?
    private var dirtyLists = Set<ListKind>()
    private var recoveryTasks: [String: Task<Void, Never>] = [:]
    private var recoveryDirty = Set<String>()
    private var recoveryGeneration = 0
    private var timelines: [ObjectIdentifier: WeakTimeline] = [:]
    private var foregroundActive = true
    private var groupMutationStates: [String: GroupMutationState] = [:]
    private var notificationRevision = 0
    private var notificationVersions: [String: Int] = [:]
    private var notificationSnapshots: [String: ChatNotificationSettingResponse] = [:]
    private var defaultsRevision = 0
    private var defaultsLoadTask: Task<Void, Error>?
    private var defaultsLoadRequested = false
    @Published private(set) var notificationDefaultsSaving = false
    let notificationPreferenceChanges = PassthroughSubject<Void, Never>()
    private var notificationExpiryTask: Task<Void, Never>?
    private var notificationExpiry: Date?

    func notificationChatSnapshot(_ chat: ChatListItem) -> ChatListItem {
        guard notificationVersions[chat.id] != nil, let snapshot = notificationSnapshots[chat.id]
        else { return chat }
        return chat.withNotificationState(
            mutedUntil: snapshot.mutedUntil, muteOverride: snapshot.muteOverride,
            isMuted: snapshot.isMuted, archived: chat.archived)
    }

    func trackNotificationExpiry(for chat: ChatListItem) {
        if notificationSnapshots[chat.id] == nil {
            notificationSnapshots[chat.id] = .init(
                chatId: chat.id, kind: chat.kind, archived: chat.archived,
                muteOverride: chat.muteOverride, mutedUntil: chat.mutedUntil,
                isMuted: chat.notificationMuted(defaults: state.notificationDefaults))
        }
        scheduleNotificationExpiry()
    }

    private func scheduleNotificationExpiry() {
        let now = Date()
        var next: Date?
        func consider(_ date: Date?) {
            guard let date, date > now else { return }
            if next == nil || date < next! { next = date }
        }
        for chat in state.chats { consider(chat.mutedUntil) }
        for chat in state.archivedChats { consider(chat.mutedUntil) }
        for snapshot in notificationSnapshots.values { consider(snapshot.mutedUntil) }
        guard next != notificationExpiry else { return }
        notificationExpiryTask?.cancel()
        notificationExpiry = next
        guard let next else {
            notificationExpiryTask = nil
            return
        }
        notificationExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(next.timeIntervalSinceNow)) } catch { return }
            guard let self else { return }
            self.notificationExpiry = nil
            self.objectWillChange.send()
            self.notificationPreferenceChanges.send()
            self.scheduleNotificationExpiry()
        }
    }

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

        var cacheScope: CachedListScope {
            switch self {
            case .chats: .activeChats
            case .threads: .activeThreads
            case .archivedChats: .archivedChats
            case .archivedThreads: .archivedThreads
            }
        }

        static func selected(chats: Bool, threads: Bool, archived: Bool) -> [Self] {
            var lists: [Self] = []
            if chats { lists.append(archived ? .archivedChats : .chats) }
            if threads { lists.append(archived ? .archivedThreads : .threads) }
            return lists
        }

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
        displayPreferences: ConversationDisplayPreferences? = nil,
        historyCache: AccountHistoryCache? = nil,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.apiClient = apiClient
        self.onInvalidToken = onInvalidToken
        self.outgoingQueue = outgoingQueue
        self.historyCache = historyCache
        self.displayPreferences =
            displayPreferences ?? ConversationDisplayPreferences(namespace: "injected")
        drafts = ChatDraftStore(outgoingQueue: outgoingQueue)
        reactions = MessageReactionController(
            apiClient: apiClient, messageStore: conversationMessages, onInvalidToken: onInvalidToken
        )
        pins = ChatPinController(apiClient: apiClient, onInvalidToken: onInvalidToken)
        stickers = StickerLibrary(apiClient: apiClient, onInvalidToken: onInvalidToken)
        savedMessages = SavedMessageController(apiClient: apiClient, onInvalidToken: onInvalidToken)
        outgoingObservation = outgoingQueue.events.sink { [weak self] event in
            self?.applyOutgoingEvent(event)
        }
        storageObservation = outgoingQueue.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        outgoingQueue.authorizeWrite = { [weak self] chatID, threadID in
            guard let self else { throw SpeakingWriteError.unavailable }
            let key = ConversationKey(chatID: chatID, threadID: threadID)
            if self.historyCache != nil { try await self.authorizeDispatch(key) }
            else { try await self.requireSpeakingPermission(chatID: chatID, threadID: threadID) }
        }
        if historyCache != nil {
            outgoingQueue.authorizeEnqueue = { [weak self] key in
                guard let self else { throw CancellationError() }
                try await self.authorizeEnqueue(key)
            }
            reachabilityObservation = outgoingQueue.$online.removeDuplicates().sink { [weak self] online in
                self?.updateHistoryNetworkGate(pathUsable: online)
            }
        }
    }

    private func applyOutgoingEvent(_ event: OutgoingQueueEvent) {
        switch event {
        case .snapshot(let snapshot):
            guard installOutgoingSnapshot(snapshot) else { return }
            conversationMessages.replacePending(
                chatID: snapshot.chatID, threadID: snapshot.threadID,
                with: pendingProjection(chatID: snapshot.chatID, threadID: snapshot.threadID))
        case .delivered(let snapshot, let message, let published):
            // Published rows were cached atomically with settlement.
            _ = installOutgoingSnapshot(snapshot)
            if historyCache?.accessRevoked(message.chatId) == true {
                conversationMessages.replacePending(
                    chatID: snapshot.chatID, threadID: snapshot.threadID,
                    with: pendingProjection(chatID: snapshot.chatID, threadID: snapshot.threadID))
                return
            }
            let currentUserID = currentUserProfile?.uid ?? message.sender.uid
            applyMessageCreation(
                message.normalizedForRealtime(currentUserID: currentUserID),
                currentUserID: currentUserID,
                replacingPending: pendingProjection(
                    chatID: snapshot.chatID, threadID: snapshot.threadID),
                persistent: published)
        case .purged(let keys):
            for key in keys {
                conversationMessages.replacePending(
                    chatID: key.chatID, threadID: key.threadID, with: [])
            }
            drafts.discardAfterSignOutPurge()
            outgoingRevisions.removeAll()
            pendingListPreviews.removeAll()
        }
    }

    private func applyMessageCreation(
        _ message: MessageResponse, currentUserID: Int32,
        replacingPending pending: [PendingOutgoingMessage]? = nil, persistent: Bool = true
    ) {
        let message = deletedContentProjection(message) ?? message
        if message.isDeleted {
            discardDeletedReadTargets(chatID: message.chatId, ids: [message.id])
            drafts.redactReplyTargets([message.id], chatID: message.chatId)
        }
        if let pending {
            conversationMessages.replacePending(
                chatID: message.chatId, threadID: message.replyRootId,
                with: pending, acknowledging: message, persistent: persistent)
        } else {
            conversationMessages.apply(.message(message))
        }
        pins.applyRealtimeEvent(message.isDeleted ? .messageDeleted(message) : .message(message))
        let isOwnMembershipAnnouncement =
            message.replyRootId == nil
            && ((message.systemKind == .memberJoined && message.sender.uid == currentUserID)
                || (message.systemKind == .memberAdded
                    && message.systemLinks?.uid == currentUserID))
        if !isOwnMembershipAnnouncement { receivePreview(message, isNew: true) }
    }

    private func applyMessageUpdate(_ message: MessageResponse) {
        let message = deletedContentProjection(message) ?? message
        if message.isDeleted {
            applyMessageDeletion(message)
            return
        }
        conversationMessages.apply(.messageUpdated(message))
        pins.applyRealtimeEvent(.messageUpdated(message))
        receivePreview(message, isNew: false)
        if !conversationStateReady(chatID: message.chatId, threadID: message.replyRootId) {
            reconcileRow(.init(chatID: message.chatId, threadID: message.replyRootId))
        }
        refreshVisibleActivity(
            chatID: message.chatId, threadID: message.replyRootId,
            mentions: true, reactions: false)
    }

    private func applyMessageDeletion(_ message: MessageResponse) {
        let redacted = message.redactedForDeletion()
        discardDeletedReadTargets(chatID: message.chatId, ids: [message.id])
        drafts.redactReplyTargets([message.id], chatID: message.chatId)
        conversationMessages.apply(.messageDeleted(redacted))
        pins.applyRealtimeEvent(.messageDeleted(redacted))
        receivePreview(redacted, isNew: false)
        reconcileRow(.init(chatID: message.chatId, threadID: message.replyRootId))
    }

    private func deletedContentProjection(_ message: MessageResponse) -> MessageResponse? {
        let ids = conversationMessages.deletedMessageIDs(chatID: message.chatId)
        let redacted =
            message.isDeleted || ids.contains(message.id) ? message.redactedForDeletion() : nil
        if let reply = message.replyToMessage {
            if ids.contains(reply.id) {
                return (redacted ?? message).redactingReplyPreview(messageIDs: ids)
            }
            if reply.isDeleted {
                return (redacted ?? message).redactingReplyPreview(messageIDs: [reply.id])
            }
        }
        return redacted
    }

    private func redactingDeletedPreview(_ preview: MessagePreview, chatID: String)
        -> MessagePreview
    {
        let ids = conversationMessages.deletedMessageIDs(chatID: chatID)
        return preview.isDeleted || ids.contains(preview.id)
            ? preview.redactedForDeletion() : preview
    }

    private func installOutgoingSnapshot(_ snapshot: LocalConversationSnapshot) -> Bool {
        let key = ConversationKey(chatID: snapshot.chatID, threadID: snapshot.threadID)
        guard snapshot.revision >= outgoingRevisions[key, default: -1] else { return false }
        outgoingRevisions[key] = snapshot.revision
        drafts.install(snapshot)
        let preview = outgoingQueue.pendingMessages(chatID: key.chatID, threadID: key.threadID).last
        if pendingListPreviews[key] != preview { pendingListPreviews[key] = preview }
        return true
    }

    private func pendingProjection(chatID: String, threadID: String?) -> [PendingOutgoingMessage] {
        outgoingQueue.pendingMessages(chatID: chatID, threadID: threadID).map { message in
            PendingOutgoingMessage(
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
                phase: outgoingQueue.phase(of: message),
                replyToMessage: message.replyToMessage.map {
                    redactingDeletedPreview($0, chatID: message.chatID)
                },
                attachments: message.attachments, sticker: message.sticker,
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

    @Published private(set) var networkAuthorized = true
    @Published private(set) var canFetchHistory = true
    var onRetrySessionValidation: (() -> Void)?

    func canRetryHistory() -> Bool {
        if !networkAuthorized { onRetrySessionValidation?() }
        return networkAuthorized
    }

    func setNetworkAuthorized(_ authorized: Bool) {
        guard networkAuthorized != authorized else { return }
        networkAuthorized = authorized
        outgoingQueue.setDispatchAuthorized(authorized)
        updateHistoryNetworkGate(pathUsable: historyCache == nil || outgoingQueue.online)
    }

    private func updateHistoryNetworkGate(pathUsable: Bool) {
        let allowed = networkAuthorized && pathUsable
        guard canFetchHistory != allowed else { return }
        canFetchHistory = allowed
        readNetworkVersion += 1
        if !allowed {
            dispatchPermissionChecks.removeAll()
            for model in visibleTimelines() { model.historyPathChanged() }
        }
        if allowed, historyCache?.isAvailable == true, foregroundActive {
            let requestGeneration = generation
            Task { [weak self] in
                guard let self, generation == requestGeneration, networkAuthorized else { return }
                async let lists: Void = refreshActiveConversations()
                async let timelines: Void = resumeVisibleHistory()
                _ = await (lists, timelines)
            }
        }
    }

    func loadActiveChats() async { await loadList(.chats) }
    func loadActiveThreads() async { await loadList(.threads) }
    func loadArchivedChats() async { await loadList(.archivedChats) }
    func loadArchivedThreads() async { await loadList(.archivedThreads) }

    func refreshActiveChats() async { await refreshList(.chats) }
    func refreshActiveThreads() async { await refreshList(.threads) }

    func retryConversations(chats: Bool, threads: Bool, archived: Bool) async {
        guard canRetryHistory() else { return }
        await withTaskGroup(of: Void.self) { group in
            for list in ListKind.selected(chats: chats, threads: threads, archived: archived) {
                group.addTask { await self.refreshList(list, ignoringPath: true) }
            }
        }
    }
    func refreshArchivedChats() async { await refreshList(.archivedChats) }
    func refreshArchivedThreads() async { await refreshList(.archivedThreads) }

    func loadMoreSavedConversations(chats: Bool, threads: Bool, archived: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for list in ListKind.selected(chats: chats, threads: threads, archived: archived) {
                group.addTask { await self.hydrateList(list, nextPage: true) }
            }
        }
    }

    func clearHistoryPresentation() {
        messageStorageFull = false
        clearCachedListPresentation()
        savedSendDecisions.removeAll()
        for model in visibleTimelines() { model.invalidateCachedHistory() }
        replayPendingReads()
    }

    func resumeVisibleHistory() async {
        await withTaskGroup(of: Void.self) { group in
            for model in visibleTimelines() {
                group.addTask { await model.resumeNetworkHistory() }
            }
        }
    }

    func clearCachedListPresentation() {
        refreshGeneration += 1
        for refresh in refreshTasks.values { refresh.task.cancel() }
        refreshTasks.removeAll()
        for task in listHydrationTasks.values { task.cancel() }
        listHydrationTasks.removeAll()
        for task in rowTasks.values { task.cancel() }
        rowTasks.removeAll()
        dirtyRows.removeAll()
        dirtyLists.removeAll()
        invalidationTask?.cancel()
        invalidationTask = nil
        stateFallbackTask?.cancel()
        stateFallbackTask = nil
        fallbackKeys.removeAll()
        readFenceReconciliations.removeAll()
        savedListsRead.removeAll()
        savedListCursors.removeAll()
        listReadReceipts.reset()

        var snapshot = state
        snapshot.chats.removeAll()
        snapshot.threads.removeAll()
        snapshot.archivedChats.removeAll()
        snapshot.archivedThreads.removeAll()
        snapshot.listAvailability.removeAll()
        snapshot.savedListHasMore.removeAll()
        for list in ListKind.allCases {
            snapshot[keyPath: list.phase] = .idle
            snapshot[keyPath: list.refreshing] = false
            snapshot[keyPath: list.refreshFailed] = false
        }
        state = snapshot
        scheduleNotificationExpiry()
    }

    private func loadList(_ list: ListKind) async {
        let requestGeneration = generation
        let cacheRevision = historyCache?.revision
        await hydrateList(list)
        guard generation == requestGeneration, historyCache?.revision == cacheRevision,
            !Task.isCancelled
        else { return }
        let phase = state[keyPath: list.phase]
        guard phase == .idle || phase == .failed else { return }
        await refreshList(list)
    }

    private func hydrateList(_ list: ListKind, nextPage: Bool = false) async {
        guard let historyCache, historyCache.isAvailable, state[keyPath: list.phase] != .loaded
        else { return }
        if let task = listHydrationTasks[list] {
            await task.value
            return
        }
        let cursor = savedListCursors[list]
        guard nextPage ? cursor != nil : !savedListsRead.contains(list) else { return }

        let requestGeneration = generation
        let cacheRevision = historyCache.revision
        let scope = list.cacheScope
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration && !Task.isCancelled {
                    listHydrationTasks[list] = nil
                }
            }
            guard generation == requestGeneration, historyCache.revision == cacheRevision,
                !Task.isCancelled
            else { return }
            // Changes during a read may leave its rows older than a targeted removal,
            // a policy change, or a move to the opposite projection. Read again.
            while !Task.isCancelled {
                let listRevision = listStateRevision
                do {
                    let page = try await historyCache.read { try await $0.cachedList(scope, after: cursor) }
                    guard generation == requestGeneration, historyCache.revision == cacheRevision,
                        state[keyPath: list.phase] != .loaded, !Task.isCancelled
                    else { return }
                    guard listRevision == listStateRevision else { continue }
                    savedListsRead.insert(list)
                    if let page {
                        installSavedListPage(page, list: list)
                    } else if nextPage {
                        savedListCursors[list] = nil
                        state.savedListHasMore.remove(scope)
                    }
                } catch {
                    // A missing or unavailable database must not block HTTP.
                }
                return
            }
        }
        listHydrationTasks[list] = task
        await task.value
    }

    private func installSavedListPage(_ page: CachedListPage, list: ListKind) {
        let scope = list.cacheScope
        var snapshot = state
        let chats = Set(snapshot.chats.lazy.map(\.id)).union(snapshot.archivedChats.lazy.map(\.id))
        let threads = Set(snapshot.threads.lazy.map(\.conversationKey))
            .union(snapshot.archivedThreads.lazy.map(\.conversationKey))
        for item in page.items {
            switch item {
            case .chat(let saved) where !chats.contains(saved.id):
                var row = saved
                if saved.kind == .group, saved.lastMessage?.systemKind?.isMembership == true,
                    (membershipChatSettings?.showMembershipMessages
                        ?? currentUserProfile?.showMembershipMessages) != true
                        || (membershipPolicies[saved.id] ?? saved.membershipMessagePolicy)?.canView != true
                {
                    row = saved.withPreview(nil, preserveActivity: true)
                }
                if list.archived { snapshot.archivedChats.append(displayFilteredSnapshot(row)) }
                else { snapshot.chats.append(displayFilteredSnapshot(row)) }
            case .thread(let row) where !threads.contains(row.conversationKey):
                if list.archived { snapshot.archivedThreads.append(displayFilteredSnapshot(row)) }
                else { snapshot.threads.append(displayFilteredSnapshot(row)) }
            default: break
            }
        }
        if snapshot.listAvailability[scope] == nil {
            snapshot.listAvailability[scope] = .cached(complete: page.complete)
        }
        savedListCursors[list] = page.next
        if page.next != nil { snapshot.savedListHasMore.insert(scope) }
        else { snapshot.savedListHasMore.remove(scope) }
        state = snapshot
    }

    private func refreshList(_ list: ListKind, ignoringPath: Bool = false) async {
        guard networkAuthorized && (ignoringPath || canFetchHistory) else { return }
        let requestGeneration = generation
        let currentRefresh = refreshGeneration
        if let refresh = refreshTasks[list] {
            await refresh.task.value
            guard ignoringPath, !refresh.ignoresPath, !canFetchHistory, networkAuthorized,
                generation == requestGeneration, refreshGeneration == currentRefresh, !Task.isCancelled
            else { return }
            if let newer = refreshTasks[list] {
                await newer.task.value
                return
            }
        }
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
                    list, generation: requestGeneration, refreshGeneration: currentRefresh,
                    ignoringPath: ignoringPath)
            } while self.generation == requestGeneration && self.refreshGeneration == currentRefresh
                && self.networkAuthorized && (ignoringPath || self.canFetchHistory)
                && self.dirtyLists.contains(list) && !Task.isCancelled
        }
        refreshTasks[list] = (task, ignoringPath)
        await task.value
    }

    private func refreshSnapshot(
        _ list: ListKind, generation requestGeneration: Int, refreshGeneration currentRefresh: Int,
        ignoringPath: Bool
    ) async {
        let initiallyLoaded = state[keyPath: list.phase] == .loaded
        var listRevision = listStateRevision
        let readVersion = readStateVersion
        let receiptVersion = listReadReceipts.snapshot()
        if !initiallyLoaded { state[keyPath: list.phase] = .loading }
        do {
            var cursor: String?
            var cursors = Set<String>()
            var seen = Set<ConversationKey>()
            repeat {
                if membershipSettingsWrites > 0 {
                    _ = try await serializeGroupMutation(chatID: "\0membership-settings") {}
                }
                try checkListSnapshot(
                    list, generation: requestGeneration, refresh: currentRefresh, revision: listRevision,
                    ignoringPath: ignoringPath)
                let settingsRevision = membershipSettingsRevision
                let prefixCount = seen.count
                let scope = list.cacheScope
                let items: [CachedConversation]
                var snapshot: ChatState
                switch list {
                case .chats, .archivedChats:
                    let response = try await fetchChatList(list, after: cursor)
                    try checkListSnapshot(
                        list, generation: requestGeneration, refresh: currentRefresh,
                        revision: listRevision, settingsRevision: settingsRevision, ignoringPath: ignoringPath)
                    cursor = response.nextCursor
                    if let cursor, !cursors.insert(cursor).inserted { throw APIError.unavailable }

                    if let settings = response.chatSettings { acceptChatSettings(settings) }
                    var rows: [ChatListItem] = []
                    var keys = Set<String>()
                    for raw in response.chats where raw.archived == list.archived {
                        let key = ConversationKey(chatID: raw.id)
                        guard seen.insert(key).inserted else { continue }
                        rowRevisions[key, default: 0] += 1
                        keys.insert(raw.id)
                        if let policy = raw.membershipMessagePolicy {
                            acceptMembershipPolicy(policy, chatID: raw.id)
                        }
                        let read = resolveReadSnapshot(raw.readState, key: key, version: readVersion)
                        let row = displayFilteredSnapshot(raw.withReadState(read))
                        rows.append(row)
                        notificationSnapshots[row.id] = .init(
                            chatId: row.id, kind: row.kind, archived: row.archived,
                            muteOverride: row.muteOverride, mutedUntil: row.mutedUntil,
                            isMuted: row.notificationMuted(defaults: state.notificationDefaults))
                        acceptListReadReceipt(.chat(row), version: receiptVersion)
                    }
                    // Settings/policies accepted above already filter the current page and
                    // earlier rows. A different refresh still has to revalidate its baseline.
                    dirtyLists.remove(list)
                    snapshot = state
                    if list.archived {
                        snapshot.archivedChats = mergeListPage(
                            rows, into: snapshot.archivedChats, prefixCount: prefixCount,
                            keys: keys, complete: cursor == nil, key: \.id)
                        if snapshot.chats.contains(where: { keys.contains($0.id) }) {
                            snapshot.chats.removeAll { keys.contains($0.id) }
                            listStateRevision += 1
                        }
                    } else {
                        snapshot.chats = mergeListPage(
                            rows, into: snapshot.chats, prefixCount: prefixCount,
                            keys: keys, complete: cursor == nil, key: \.id)
                        if snapshot.archivedChats.contains(where: { keys.contains($0.id) }) {
                            snapshot.archivedChats.removeAll { keys.contains($0.id) }
                            listStateRevision += 1
                        }
                    }
                    items = rows.map(CachedConversation.chat)
                case .threads, .archivedThreads:
                    let response = try await fetchThreadList(list, before: cursor)
                    try checkListSnapshot(
                        list, generation: requestGeneration, refresh: currentRefresh,
                        revision: listRevision, settingsRevision: settingsRevision, ignoringPath: ignoringPath)
                    cursor = response.nextCursor
                    if let cursor, !cursors.insert(cursor).inserted {
                        Self.logger.error("Thread list refresh failed: server repeated a pagination cursor")
                        throw APIError.unavailable
                    }
                    var rows: [ThreadListItem] = []
                    var keys = Set<ConversationKey>()
                    for raw in response.threads where raw.archived == list.archived {
                        let key = raw.conversationKey
                        guard seen.insert(key).inserted else { continue }
                        rowRevisions[key, default: 0] += 1
                        keys.insert(key)
                        let read = resolveReadSnapshot(raw.readState, key: key, version: readVersion)
                        let row = displayFilteredSnapshot(raw.withReadState(read))
                        rows.append(row)
                        acceptListReadReceipt(.thread(row), version: receiptVersion)
                        cacheMembership(.init(subscribed: true, archived: row.archived), key: key)
                    }
                    snapshot = state
                    if list.archived {
                        snapshot.archivedThreads = mergeListPage(
                            rows, into: snapshot.archivedThreads, prefixCount: prefixCount,
                            keys: keys, complete: cursor == nil, key: \.conversationKey)
                        if snapshot.threads.contains(where: { keys.contains($0.conversationKey) }) {
                            snapshot.threads.removeAll { keys.contains($0.conversationKey) }
                            listStateRevision += 1
                        }
                    } else {
                        snapshot.threads = mergeListPage(
                            rows, into: snapshot.threads, prefixCount: prefixCount,
                            keys: keys, complete: cursor == nil, key: \.conversationKey)
                        if snapshot.archivedThreads.contains(where: { keys.contains($0.conversationKey) }) {
                            snapshot.archivedThreads.removeAll { keys.contains($0.conversationKey) }
                            listStateRevision += 1
                        }
                    }
                    items = rows.map(CachedConversation.thread)
                }

                let complete = cursor == nil
                snapshot.listAvailability[scope] = .server(complete: complete || initiallyLoaded)
                if complete {
                    snapshot[keyPath: list.phase] = .loaded
                    snapshot[keyPath: list.refreshFailed] = false
                    savedListCursors[list] = nil
                    snapshot.savedListHasMore.remove(scope)
                }
                let membership = complete ? seen : nil
                historyCache?.submit { db, epoch in
                    try await db.cacheList(scope, items: items, seen: membership, epoch: epoch)
                }
                state = snapshot
                scheduleNotificationExpiry()
                updateTimelineReadStates()
                fallbackConversationStates()
                listRevision = listStateRevision
                if !complete { await Task.yield() }
            } while cursor != nil
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

    private func checkListSnapshot(
        _ list: ListKind, generation requestGeneration: Int, refresh currentRefresh: Int,
        revision: Int, settingsRevision: Int? = nil, ignoringPath: Bool
    ) throws {
        try Task.checkCancellation()
        guard generation == requestGeneration, refreshGeneration == currentRefresh,
            networkAuthorized && (ignoringPath || canFetchHistory)
        else { throw CancellationError() }
        guard listStateRevision == revision,
            settingsRevision.map({ membershipSettingsRevision == $0 && membershipSettingsWrites == 0 }) ?? true
        else {
            dirtyLists.insert(list)
            throw CancellationError()
        }
    }

    // The accepted prefix retains the server's ordering. The untouched tail is
    // removed only by the final successful page, never by a partial refresh.
    private func mergeListPage<Row, Key: Hashable>(
        _ rows: [Row], into previous: [Row], prefixCount: Int, keys: Set<Key>,
        complete: Bool, key: KeyPath<Row, Key>
    ) -> [Row] {
        var merged = Array(previous.prefix(prefixCount))
        merged.append(contentsOf: rows)
        if !complete {
            merged.append(contentsOf: previous.dropFirst(prefixCount).filter {
                !keys.contains($0[keyPath: key])
            })
        }
        return merged
    }

    private func fetchChatList(_ list: ListKind, after cursor: String?) async throws -> ListChatsResponse {
        try await apiClient.listChats(query: .init(after: cursor, archived: list.archived))
    }

    private func fetchThreadList(_ list: ListKind, before cursor: String?) async throws -> ListThreadsResponse {
        try await apiClient.listThreads(query: .init(before: cursor, archived: list.archived))
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
        guard canFetchHistory, pendingListActions[conversation] == nil else { return }
        let requestGeneration = generation
        let cacheRevision = historyCache?.revision
        pendingListActions[conversation] = action
        listActionError = nil
        defer {
            if generation == requestGeneration {
                pendingListActions.removeValue(forKey: conversation)
                if action == .markUnread { replayPendingReads() }
            }
        }
        do {
            try await serializeGroupMutation(chatID: conversation.chatID) {
                guard self.generation == requestGeneration, self.historyCache?.revision == cacheRevision
                else { throw CancellationError() }
                await self.performListActionRequest(
                    action, conversation: conversation, generation: requestGeneration,
                    cacheRevision: cacheRevision)
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
        generation requestGeneration: Int, cacheRevision: UInt64?
    ) async {
        if action != .markRead { beginLocalStateWrite(conversation) }
        defer {
            if action != .markRead {
                finishLocalStateWrite(conversation, generation: requestGeneration)
            }
        }
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
                guard generation == requestGeneration, historyCache?.revision == cacheRevision
                else { return }
                // Move only after server acceptance and retain any read/preview updates
                // received while the mutation was in flight.
                switch item {
                case .chat(let original):
                    let latest = chat(id: original.id) ?? original
                    applyArchiveState(to: latest, archived: archived)
                case .thread(let original):
                    let latest =
                        thread(
                            chatID: original.chatId,
                            threadID: original.threadRootMessage.id.description)
                        ?? original
                    install(latest.withArchived(archived))
                }
            case .notificationSettings:
                // The list opens the shared notification chooser; no implicit mutation.
                return
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
                // Do not let a previously handed-off local read race this rewind
                // on the server. The pending list action blocks new automatic reads.
                if let acknowledgement = readAcknowledgements[conversation] {
                    _ = try? await acknowledgement.task.value
                }
                try Task.checkCancellation()
                guard generation == requestGeneration, canFetchHistory else { return }
                let response = try await apiClient.markChatUnread(chatID: conversation.chatID)
                guard generation == requestGeneration else { return }
                applyReadState(
                    response, chatID: conversation.chatID, threadID: nil, resetWatermark: true)
            }
            if action != .markRead { listStateRevision += 1 }
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
            if state.threads.contains(where: { $0.conversationKey == key }) {
                state.threads.removeAll { $0.conversationKey == key }
            }
            if state.archivedThreads.contains(where: { $0.conversationKey == key }) {
                state.archivedThreads.removeAll { $0.conversationKey == key }
            }
            removeCachedListRow(key)
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
        let chat = displayFilteredSnapshot(chat)
        let previousExpiry = self.chat(id: chat.id)?.mutedUntil
        conversationReadStates[.init(chatID: chat.id)] = .init(
            lastReadMessageId: chat.lastReadMessageId, unreadCount: chat.unreadCount,
            unreadMentions: chat.unreadMentions, unreadReactions: chat.unreadReactions)
        let target: WritableKeyPath<ChatState, [ChatListItem]> =
            chat.archived ? \.archivedChats : \.chats
        let other: WritableKeyPath<ChatState, [ChatListItem]> =
            chat.archived ? \.chats : \.archivedChats
        if state[keyPath: other].contains(where: { $0.id == chat.id }) {
            state[keyPath: other].removeAll { $0.id == chat.id }
        }
        if let index = state[keyPath: target].firstIndex(where: { $0.id == chat.id }) {
            if state[keyPath: target][index] != chat {
                state[keyPath: target][index] = chat
                persistListRow(.chat(chat))
            }
        } else {
            state[keyPath: target].insert(chat, at: 0)
            persistListRow(.chat(chat))
        }
        if previousExpiry != chat.mutedUntil { scheduleNotificationExpiry() }
    }

    private func install(_ thread: ThreadListItem) {
        let thread = displayFilteredSnapshot(thread)
        conversationReadStates[thread.conversationKey] = .init(
            lastReadMessageId: thread.lastReadMessageId, unreadCount: thread.unreadCount,
            unreadMentions: thread.unreadMentions, unreadReactions: thread.unreadReactions)
        let target: WritableKeyPath<ChatState, [ThreadListItem]> =
            thread.archived ? \.archivedThreads : \.threads
        let other: WritableKeyPath<ChatState, [ThreadListItem]> =
            thread.archived ? \.threads : \.archivedThreads
        if state[keyPath: other].contains(where: { $0.conversationKey == thread.conversationKey }) {
            state[keyPath: other].removeAll { $0.conversationKey == thread.conversationKey }
        }
        if let index = state[keyPath: target].firstIndex(where: {
            $0.chatId == thread.chatId && $0.threadRootMessage.id == thread.threadRootMessage.id
        }) {
            if state[keyPath: target][index] != thread {
                state[keyPath: target][index] = thread
                persistListRow(.thread(thread))
            }
        } else {
            state[keyPath: target].insert(thread, at: 0)
            persistListRow(.thread(thread))
        }
        cacheMembership(
            .init(subscribed: true, archived: thread.archived), key: thread.conversationKey)
    }

    private func persistListRow(_ item: CachedConversation) {
        historyCache?.submit { db, epoch in try await db.cacheConversation(item, epoch: epoch) }
    }

    private func removeCachedListRow(_ key: ConversationKey) {
        historyCache?.submit(required: true) { db, epoch in
            try await db.removeCachedConversation(key, epoch: epoch)
        }
    }

    private func applyArchiveState(to chat: ChatListItem, archived: Bool) {
        install(
            chat.withNotificationState(
                mutedUntil: chat.mutedUntil, muteOverride: chat.muteOverride,
                isMuted: chat.isMuted, archived: archived))
    }

    /// Threads may belong to an archived parent absent from the active chat list.
    func chatForThread(_ thread: ThreadListItem) async throws -> ChatListItem {
        if let chat = chat(id: thread.chatId) { return chat }
        if !canFetchHistory {
            return ChatListItem(id: thread.chatId, name: thread.chatName, avatar: thread.chatAvatar,
                unreadCount: 0, archived: thread.archived, kind: thread.chatKind, peer: thread.peer)
        }
        let requestGeneration = generation
        do {
            let info = try await groupInfo(chatID: thread.chatId)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            guard info.id == thread.chatId else {
                Self.logger.error("Thread parent load failed: server returned a different chat")
                throw APIError.unexpectedResponse
            }
            return ChatListItem(
                id: thread.chatId, name: thread.chatName, avatar: thread.chatAvatar,
                unreadCount: 0, archived: false, kind: info.kind, peer: info.peer,
                membershipMessagePolicy: info.membershipMessagePolicy)
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

    /// Payload identifiers are hints; authorize the message before resolving its
    /// actual root/thread scope, including parents absent from the visible list.
    func resolveMessageLink(chatID: String, messageID: MessageID) async throws
        -> (MessageResponse, ChatListItem)
    {
        let requestGeneration = generation
        return try await performGroupRequest(generation: requestGeneration) {
            async let infoRequest = groupInfo(chatID: chatID)
            async let messageRequest = apiClient.getMessage(chatID: chatID, messageID: messageID)
            let (info, message) = try await (infoRequest, messageRequest)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            guard info.id == chatID, message.chatId == chatID, message.id == messageID else {
                throw APIError.unexpectedResponse
            }
            let cached = chat(id: info.id)
            let resolved = ChatListItem(
                id: info.id, name: info.name, avatar: info.avatar,
                lastMessageAt: cached?.lastMessageAt,
                unreadCount: cached?.unreadCount ?? 0,
                unreadMentions: cached?.unreadMentions ?? 0,
                unreadReactions: cached?.unreadReactions ?? 0,
                lastReadMessageId: cached?.lastReadMessageId,
                peerLastReadMessageId: cached?.peerLastReadMessageId,
                lastMessage: cached?.lastMessage,
                mutedUntil: cached != nil ? cached?.mutedUntil : info.mutedUntil,
                muteOverride: cached != nil ? cached?.muteOverride : info.muteOverride,
                isMuted: cached != nil ? cached?.isMuted : info.isMuted,
                archived: cached?.archived ?? false,
                kind: info.kind, peer: info.peer,
                membershipMessagePolicy: info.membershipMessagePolicy)
            return (message, resolved)
        }
    }

    func chatForNotification(_ route: PushNotificationRoute) async throws -> ChatListItem {
        let requestGeneration = generation
        do {
            let (message, chat) = try await resolveMessageLink(
                chatID: route.chatID, messageID: route.messageID)
            guard message.replyRootId == route.threadID else { throw APIError.unexpectedResponse }
            return chat
        } catch let error as APIError {
            switch error {
            case .http(status: 404, body: _), .invalidResponse(statusCode: 404):
                // A notification can outlive its message. Authorize the chat
                // independently; the timeline handles an unavailable reveal target.
                let info = try await groupInfo(chatID: route.chatID)
                try Task.checkCancellation()
                guard generation == requestGeneration else { throw CancellationError() }
                guard info.id == route.chatID else { throw APIError.unexpectedResponse }
                return notificationChatSnapshot(groupChatSnapshot(info))
            default:
                throw error
            }
        }
    }

    /// Identifier-filtered reads reconcile only rows whose membership/preview is unknown.
    private func reconcileRow(_ key: ConversationKey) {
        dirtyRows.insert(key)
        rowRevisions[key, default: 0] += 1
        listStateRevision += 1
        guard canFetchHistory, rowTasks[key] == nil else { return }
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
                guard generation == requestGeneration, refreshGeneration == currentRefresh,
                    canFetchHistory
                else {
                    return
                }
                guard localStateWrites[key] == nil else { return }
                if key.threadID == nil, membershipSettingsWrites > 0 {
                    _ = try? await serializeGroupMutation(chatID: "\0membership-settings") {}
                    guard generation == requestGeneration, refreshGeneration == currentRefresh
                    else {
                        return
                    }
                }
                dirtyRows.remove(key)
                let revision = rowRevisions[key, default: 0]
                let receiptVersion = listReadReceipts.snapshot()
                let readVersion = readStateVersion
                let settingsRevision = membershipSettingsRevision
                let policyRevision = membershipPolicyRevisions[key.chatID, default: 0]
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
                            listStateRevision += 1
                            if let found {
                                let response = resolveReadSnapshot(
                                    found.readState, key: key, version: readVersion)
                                let found = found.withReadState(response)
                                install(found)
                                acceptListReadReceipt(.thread(found), version: receiptVersion)
                            } else {
                                state.threads.removeAll { $0.conversationKey == key }
                                state.archivedThreads.removeAll { $0.conversationKey == key }
                                removeCachedListRow(key)
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
                            guard generation == requestGeneration,
                                refreshGeneration == currentRefresh
                            else { return }
                            guard membershipSettingsRevision == settingsRevision,
                                membershipSettingsWrites == 0,
                                membershipPolicyRevisions[key.chatID, default: 0] == policyRevision
                            else {
                                dirtyRows.insert(key)
                                break
                            }
                            if let settings = response.chatSettings { acceptChatSettings(settings) }
                            if found != nil { break }
                        }
                        guard generation == requestGeneration, refreshGeneration == currentRefresh
                        else { return }
                        guard membershipSettingsRevision == settingsRevision,
                            membershipSettingsWrites == 0,
                            membershipPolicyRevisions[key.chatID, default: 0] == policyRevision
                        else {
                            dirtyRows.insert(key)
                            continue
                        }
                        if rowRevisions[key, default: 0] == revision, localStateWrites[key] == nil {
                            listStateRevision += 1
                            if let found {
                                if let policy = found.membershipMessagePolicy {
                                    acceptMembershipPolicy(policy, chatID: found.id)
                                }
                                let response = resolveReadSnapshot(
                                    found.readState, key: key, version: readVersion)
                                let found = found.withReadState(response)
                                install(found)
                                acceptListReadReceipt(.chat(found), version: receiptVersion)
                            } else {
                                state.chats.removeAll { $0.id == key.chatID }
                                state.archivedChats.removeAll { $0.id == key.chatID }
                                removeCachedListRow(key)
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
        if key.threadID == nil, message.systemKind?.isMembership == true,
            chat(id: message.chatId)?.kind == .group
                || groupInfoByChatID[message.chatId]?.kind == .group,
            conversationMessages.hidesMembershipMessages(chatID: message.chatId)
        {
            reconcileRow(key)
            return
        }
        rowRevisions[key, default: 0] += 1
        listStateRevision += 1
        func replaces(_ preview: MessagePreview?) -> Bool {
            guard let preview else { return isNew }
            if preview.id == message.id { return !isNew || message.isDeleted }
            return isNew && preview.id < message.id
        }
        if let rootID = key.threadID {
            if let current = thread(chatID: key.chatID, threadID: rootID) {
                if replaces(current.lastReply) {
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
                if replaces(current.lastMessage) {
                    install(current.withPreview(message.replyPreview))
                }
            } else if isNew {
                reconcileRow(key)
            }
            for item in state.threads + state.archivedThreads
            where item.chatId == message.chatId && item.threadRootMessage.id == message.id
                && replaces(item.threadRootMessage)
            {
                install(item.withActivity(root: message.replyPreview))
            }
        }
        if !conversationStateReady(chatID: key.chatID, threadID: key.threadID) {
            fallbackConversationStates(key)
        }
    }

    private func invalidateChatList() {
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
        let cacheRevision = historyCache?.revision
        switch event {
        case .message, .messageUpdated, .messageDeleted: break
        default: pins.applyRealtimeEvent(event)
        }
        switch event {
        case .groupSpeakingModeChanged(let response):
            acceptGroupSpeakingMode(response)
        case .memberSpeakingModeChanged(let response):
            acceptMemberSpeakingMode(response)
        case .chatSettingsChanged(let settings):
            acceptChatSettings(settings)
        case .membershipMessagePolicyChanged(let payload):
            historyCache?.invalidatePolicy(chatID: payload.chatId)
            membershipPolicies.removeValue(forKey: payload.chatId)
            conversationMessages.setMembershipPolicy(.init(visibility: .nobody, canView: false), chatID: payload.chatId)
            membershipPolicyRevisions[payload.chatId, default: 0] += 1
            conversationMessages.invalidateMembershipSnapshots(chatID: payload.chatId)
            groupInfoRevisions[payload.chatId, default: 0] += 1
            groupInfoInvalidations.insert(payload.chatId)
            invalidateMembershipVisibility(chatID: payload.chatId)
        case .chatMembershipChanged(let payload):
            invalidateSendPermissions(chatID: payload.chatId)
            historyCache?.invalidatePolicy(chatID: payload.chatId)
            membershipPolicies.removeValue(forKey: payload.chatId)
            conversationMessages.setMembershipPolicy(.init(visibility: .nobody, canView: false), chatID: payload.chatId)
            confirmedThreadRoots.removeAll()
            membershipPolicyRevisions[payload.chatId, default: 0] += 1
            conversationMessages.invalidateMembershipSnapshots(chatID: payload.chatId)
            groupInfoRevisions[payload.chatId, default: 0] += 1
            groupInfoByChatID.removeValue(forKey: payload.chatId)
            memberSpeakingModesByChatID.removeValue(forKey: payload.chatId)
            groupInfoInvalidations.insert(payload.chatId)
            reconcileRow(.init(chatID: payload.chatId))
            invalidateConversationWatches()
            scheduleRecovery(chatID: payload.chatId, membershipOnly: true)
        case .message(let message):
            let requestGeneration = generation
            let normalized = message.normalizedForRealtime(currentUserID: currentUserID)
            if normalized.isDeleted { discardDeletedReadTargets(chatID: normalized.chatId, ids: [normalized.id]) }
            let disposition =
                normalized.isDeleted
                ? await outgoingQueue.acceptDeletion(normalized)
                : await outgoingQueue.acceptAcknowledgement(normalized)
            guard generation == requestGeneration, historyCache?.revision == cacheRevision,
                disposition == .unrelated else { return }
            historyCache?.accept(.message(normalized), fromSocket: true)
            applyMessageCreation(normalized, currentUserID: currentUserID)
        case .messageUpdated(let message):
            let requestGeneration = generation
            let normalized = message.normalizedForRealtime(currentUserID: currentUserID)
            if normalized.isDeleted { discardDeletedReadTargets(chatID: normalized.chatId, ids: [normalized.id]) }
            let disposition =
                normalized.isDeleted
                ? await outgoingQueue.acceptDeletion(normalized)
                : await outgoingQueue.acceptAcknowledgement(normalized)
            guard generation == requestGeneration, historyCache?.revision == cacheRevision,
                disposition == .unrelated else { return }
            historyCache?.accept(.messageUpdated(normalized), fromSocket: true)
            applyMessageUpdate(normalized)
        case .messageDeleted(let message):
            let requestGeneration = generation
            let normalized = message.normalizedForRealtime(currentUserID: currentUserID)
            discardDeletedReadTargets(chatID: normalized.chatId, ids: [normalized.id])
            let disposition = await outgoingQueue.acceptDeletion(normalized)
            guard generation == requestGeneration, historyCache?.revision == cacheRevision,
                disposition == .unrelated else { return }
            historyCache?.accept(.messageDeleted(normalized), fromSocket: true)
            applyMessageDeletion(normalized)
        case .reactionUpdated(let payload):
            let normalized = RealtimeServerEvent.reactionUpdated(ReactionUpdatePayload(
                messageId: payload.messageId, chatId: payload.chatId,
                reactions: payload.reactions.map { $0.normalizedForRealtime(currentUserID: currentUserID) }))
            historyCache?.accept(normalized, fromSocket: true)
            conversationMessages.apply(normalized)
        case .messagesBulkDeleted(let payload):
            let ids = Set(payload.messageIds)
            let requestGeneration = generation
            discardDeletedReadTargets(chatID: payload.chatId, ids: ids)
            for audio in outgoingQueue.acknowledgedPendingAudioMessages
            where audio.chatId == payload.chatId && ids.contains(audio.id) {
                _ = await outgoingQueue.acceptDeletion(audio)
                guard generation == requestGeneration, historyCache?.revision == cacheRevision else { return }
            }
            drafts.redactReplyTargets(ids, chatID: payload.chatId)
            historyCache?.accept(event, fromSocket: true)
            conversationMessages.apply(event)
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
            historyCache?.accept(event, fromSocket: true)
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
                applyArchiveState(to: chat, archived: payload.archived)
            }
            listStateRevision += 1
            rowRevisions[.init(chatID: payload.chatId), default: 0] += 1
            if chat(id: payload.chatId) == nil {
                reconcileRow(.init(chatID: payload.chatId))
            }
        case .notificationSettingsChanged(let payload):
            defaultsRevision += 1
            state.notificationDefaults = payload
            listStateRevision += 1
            notificationPreferenceChanges.send()
        case .chatNotificationSettingChanged(let payload):
            notificationRevision += 1
            notificationVersions[payload.chatId] = notificationRevision
            acceptNotificationSetting(payload)
        case .notificationExceptionsCleared(let payload):
            acceptClearedNotificationExceptions(payload)
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
                reactions: payload.notificationType == .reaction,
                reactionMessageID: payload.notificationType == .reaction ? payload.messageId : nil)
        case .readReceiptChanged(let payload):
            if payload.privacyChanged == true || payload.readerUid == nil
                || payload.readerUid != currentUserProfile?.uid
            {
                refreshListReadReceipts(
                    chatID: payload.chatId, threadID: payload.threadRootId?.description,
                    clear: payload.privacyChanged == true || payload.readerUid == nil)
            }
            for model in visibleTimelines() where model.chatID == payload.chatId {
                model.readReceiptChanged(payload)
            }
        case .friendRequestResolved, .friendshipRemoved:
            if case .friendRequestResolved(let payload) = event {
                invalidateSendPermissions(peerUID: payload.byUid)
            } else if case .friendshipRemoved(let payload) = event {
                invalidateSendPermissions(peerUID: payload.actorUid)
            }
            invalidateChatList()
            invalidateReadReceipts()
            invalidateIndividualPresence()
            socialInvalidations.send(())
        case .friendRequestReceived:
            socialInvalidations.send(())
        case .stickerPackOrderUpdated(let payload):
            stickers.setPackOrder(payload.order)
        case .conversationUnread(let payload):
            acceptUnread(payload)
        case .conversationUnreadError(let payload):
            guard payload.requestId == unreadRequestID else { return }
            unreadFullRequestID = nil
            if state.mainUnread != nil { state.mainUnread = nil }
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
            .pinRemoved, .threadPinRemoved:
            break
        case .unknown:
            break
        }
    }

    func previewLinks(chatID: String, urls: [String]) async throws -> [MessageLinkPreview] {
        let requestGeneration = generation
        let previews = try await apiClient.previewLinks(chatID: chatID, urls: urls)
        guard generation == requestGeneration else { throw CancellationError() }
        return previews
    }

    func updateMessage(
        _ message: MessageResponse, text: String, metadata: MessageMetadataInput? = nil
    ) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
            text != message.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                || metadata != nil
        else {
            return false
        }
        let requestGeneration = generation
        messageUpdateError = nil
        var appliedOptimistically = false
        do {
            try await requireSpeakingPermission(
                chatID: message.chatId, threadID: message.replyRootId?.description)
            guard generation == requestGeneration else { return false }
            let optimistic = message.replacingMessageText(text)
            conversationMessages.apply(.messageUpdated(optimistic), persistent: false)
            pins.applyRealtimeEvent(.messageUpdated(optimistic))
            appliedOptimistically = true
            let updated = try await apiClient.updateMessage(
                chatID: message.chatId, messageID: message.id,
                body: .init(message: text, metadata: metadata))
            guard generation == requestGeneration else { return false }
            historyCache?.accept(.messageUpdated(updated), fromSocket: false)
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
            if appliedOptimistically {
                conversationMessages.apply(.messageUpdated(message), persistent: false)
                pins.applyRealtimeEvent(.messageUpdated(message))
            }
            if let mode = (error as? APIError)?.speakingRestriction {
                messageUpdateError = mode.restrictionExplanation
            } else if let error = error as? SpeakingWriteError {
                messageUpdateError = error.localizedDescription
            }
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
            let disposition = await outgoingQueue.acceptDeletion(message.redactedForDeletion())
            guard generation == requestGeneration else { return false }
            if disposition == .unrelated {
                historyCache?.accept(.messageDeleted(message), fromSocket: false)
                applyMessageDeletion(message)
            }
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            if case APIError.invalidToken = error { await onInvalidToken() }
            return false
        }
    }

    /// Applies only IDs explicitly confirmed by the atomic server operation.
    func bulkRecallMessages(_ messages: [MessageResponse]) async throws -> Set<MessageID> {
        guard let first = messages.first, messages.count <= 100,
            Set(messages.map(\.id)).count == messages.count,
            messages.allSatisfy({
                $0.chatId == first.chatId && !$0.isDeleted && $0.messageType != .system
                    && !deletingMessageIDs.contains($0.id)
            })
        else { throw APIError.unavailable }
        let requestGeneration = generation
        let ids = Set(messages.map(\.id))
        deletingMessageIDs.formUnion(ids)
        defer {
            if generation == requestGeneration { deletingMessageIDs.subtract(ids) }
        }
        let payload = try await performGroupRequest(generation: requestGeneration) {
            try await apiClient.bulkDeleteMessages(
                chatID: first.chatId, body: .init(messageIds: messages.map(\.id)))
        }
        guard payload.chatId == first.chatId, Set(payload.messageIds).isSubset(of: ids),
            let uid = currentUserProfile?.uid
        else { throw APIError.unavailable }
        // Reuse the websocket reconciliation path so pins, reply previews and all
        // mounted root/thread timelines observe the same authoritative tombstones.
        await applyRealtimeEvent(.messagesBulkDeleted(payload), currentUserID: uid)
        return Set(payload.messageIds)
    }

    func setRealtimeStatus(_ status: RealtimeConnectionStatus) {
        guard state.realtimeStatus != status else { return }
        state.realtimeStatus = status
        if status != .connected {
            clearPresence()
            clearConversationWatches()
            membershipStates.removeAll()
            membershipRevision += 1
            groupInfoInvalidations.formUnion(groupInfoByChatID.keys)
            confirmedThreadRoots.removeAll()
        }
        if status == .connected { refreshListReadReceipts(clear: true) }
        if status == .connected {
            Task { try? await loadNotificationDefaults() }
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

    func friendPresenceSettings(peerUID: Int32) async throws -> FriendPresenceSettingsResponse {
        try await performGroupRequest(generation: generation) {
            try await apiClient.friendPresenceSettings(peerUID: peerUID)
        }
    }

    func updateFriendPresenceSettings(peerUID: Int32, override: FriendPresenceOverride)
        async throws -> FriendPresenceSettingsResponse
    {
        let requestGeneration = generation
        return try await performGroupRequest(generation: requestGeneration) {
            let settings = try await apiClient.updateFriendPresenceSettings(
                peerUID: peerUID, override: override)
            guard generation == requestGeneration else { throw CancellationError() }
            invalidateIndividualPresence()
            return settings
        }
    }

    func readReceipt(chatID: String, threadID: MessageID?) async throws -> ReadReceiptResponse {
        let receiptVersion = listReadReceipts.snapshot()
        let response = try await performGroupRequest(generation: generation) {
            try await apiClient.readReceipt(chatID: chatID, threadID: threadID)
        }
        listReadReceipts.acceptIfKnown(
            response.lastReadMessageId,
            for: .init(chatID: chatID, threadID: threadID?.description), version: receiptVersion)
        return response
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

    let socialInvalidations = PassthroughSubject<Void, Never>()

    func searchUsers(query: String) async throws -> SearchUsersResponse {
        try await performGroupRequest(generation: generation) {
            try await apiClient.searchUsers(query: query)
        }
    }

    func searchJoinedGroups(query: String, after: String?) async throws -> SocialGroupsResponse {
        try await performGroupRequest(generation: generation) {
            try await apiClient.searchJoinedGroups(query: query, after: after)
        }
    }

    func friendAddInfo(uid: Int32) async throws -> FriendVerificationSettings {
        try await performGroupRequest(generation: generation) {
            try await apiClient.friendAddInfo(uid: uid)
        }
    }

    func friendVerificationSettings() async throws -> FriendVerificationSettings {
        try await performGroupRequest(generation: generation) {
            try await apiClient.friendVerificationSettings()
        }
    }

    func updateFriendVerificationSettings(_ settings: FriendVerificationSettings) async throws
        -> FriendVerificationSettings
    {
        try await performGroupRequest(generation: generation) {
            try await apiClient.updateFriendVerificationSettings(settings)
        }
    }

    func listFriendRequests(archived: Bool) async throws -> FriendRequestsResponse {
        try await performGroupRequest(generation: generation) {
            try await apiClient.listFriendRequests(archived: archived)
        }
    }

    func createFriendRequest(toUID: Int32, message: String?) async throws -> FriendRequest {
        let requestGeneration = generation
        return try await performGroupRequest(generation: requestGeneration) {
            let result = try await apiClient.createFriendRequest(toUID: toUID, message: message)
            guard generation == requestGeneration else { throw CancellationError() }
            invalidateReadReceipts(peerUID: toUID)
            invalidateIndividualPresence()
            invalidateChatList()
            socialInvalidations.send(())
            return result
        }
    }

    func decideFriendRequest(id: String, decision: FriendRequestDecision) async throws {
        let requestGeneration = generation
        try await performGroupRequest(generation: requestGeneration) {
            try await apiClient.decideFriendRequest(id: id, decision: decision)
            guard generation == requestGeneration else { throw CancellationError() }
            invalidateReadReceipts()
            invalidateIndividualPresence()
            invalidateChatList()
            socialInvalidations.send(())
        }
    }

    func blockedUsers() async throws -> BlockedUsersResponse {
        try await performGroupRequest(generation: generation) {
            try await apiClient.blockedUsers()
        }
    }

    /// A directory or relationship may reference an archived chat absent from the visible list.
    func socialChat(id: String) async throws -> ChatListItem {
        let info = try await groupInfo(chatID: id)
        guard info.id == id else { throw APIError.unexpectedResponse }
        return chat(id: id)
            ?? ChatListItem(
                id: id, name: info.name, avatar: info.avatar, unreadCount: 0,
                mutedUntil: info.mutedUntil, muteOverride: info.muteOverride, isMuted: info.isMuted,
                archived: false, kind: info.kind, peer: info.peer,
                membershipMessagePolicy: info.membershipMessagePolicy)
    }

    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse {
        let response = try await performGroupRequest(generation: generation) {
            try await apiClient.friendRelationship(peerUID: peerUID)
        }
        guard response.peerUid == peerUID else { throw APIError.unexpectedResponse }
        return response
    }

    func removeFriend(peerUID: Int32) async throws {
        let requestGeneration = generation
        try await performGroupRequest(generation: requestGeneration) {
            try await apiClient.removeFriend(peerUID: peerUID)
            guard generation == requestGeneration else { throw CancellationError() }
            invalidateSendPermissions(peerUID: peerUID)
            invalidateReadReceipts(peerUID: peerUID)
            invalidateIndividualPresence()
            invalidateChatList()
            socialInvalidations.send(())
        }
    }

    func setUserBlocked(peerUID: Int32, blocked: Bool) async throws {
        let requestGeneration = generation
        try await performGroupRequest(generation: requestGeneration) {
            if blocked {
                try await apiClient.blockUser(uid: peerUID)
            } else {
                try await apiClient.unblockUser(uid: peerUID)
            }
            guard generation == requestGeneration else { throw CancellationError() }
            invalidateSendPermissions(peerUID: peerUID)
            invalidateReadReceipts(peerUID: peerUID)
            invalidateIndividualPresence()
            invalidateChatList()
            socialInvalidations.send(())
        }
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
        // Clear every cached scope conservatively: a thread-only list may not
        // contain the peer profile needed to safely narrow a policy change.
        refreshListReadReceipts(clear: true)
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

    private func acceptListReadReceipt(_ item: ConversationListItem, version: Int) {
        let value: MessageID?
        switch item {
        case .chat(let chat):
            guard chat.kind == .dm else { return }
            value = chat.peerLastReadMessageId
        case .thread(let thread):
            guard thread.chatKind == .dm else { return }
            value = thread.peerLastReadMessageId
        }
        if !listReadReceipts.accept(value, for: item.id, version: version) {
            // A new row can arrive from a list request begun before revocation.
            // Keep its preview, but authorize its receipt with a fresh scoped read.
            refreshListReadReceipts(chatID: item.id.chatID, threadID: item.id.threadID)
        }
    }

    private func refreshListReadReceipts(
        chatID: String? = nil, threadID: String? = nil, clear: Bool = false
    ) {
        listReadReceipts.refresh(chatID: chatID, threadID: threadID, clear: clear) {
            [weak self] key in
            guard let self else { throw CancellationError() }
            return try await readReceipt(
                chatID: key.chatID, threadID: key.threadID.flatMap(MessageID.init)
            ).lastReadMessageId
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
        if foregroundActive { outgoingQueue.resynchronizePublications() }
        guard canFetchHistory else { return }
        let models = visibleTimelines()
        let requestGeneration = generation
        await withTaskGroup(of: Void.self) { group in
            for model in models { group.addTask { await model.reconcileAfterReconnect() } }
        }
        guard generation == requestGeneration, canFetchHistory else { return }
        let groupIDs = Set(groupInfoByChatID.keys).union(
            models.filter(\.isGroupChat).map(\.chatID))
        await withTaskGroup(of: Void.self) { group in
            let activeChatIDs = Set(models.filter { $0.threadID == nil }.map(\.chatID))
            group.addTask { await self.pins.reconcileAfterReconnect(activeChatIDs: activeChatIDs) }
            for chatID in groupIDs {
                group.addTask { _ = try? await self.groupInfo(chatID: chatID) }
            }
        }
    }

    private func visibleTimelines() -> [ConversationTimelineModel] {
        timelines = timelines.filter { $0.value.value != nil }
        return timelines.values.compactMap(\.value)
    }

    private func scheduleRecovery(chatID: String, membershipOnly: Bool = false) {
        recoveryDirty.insert(chatID)
        if !membershipOnly { fullSnapshotRecoveries.insert(chatID) }
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
                if self.groupInfoInvalidations.contains(chatID) {
                    _ = try? await self.groupInfo(chatID: chatID)
                    guard self.generation == requestGeneration,
                        self.recoveryGeneration == currentRecovery
                    else { return }
                }
                let fullSnapshot = self.fullSnapshotRecoveries.remove(chatID) != nil
                let models = self.visibleTimelines().filter {
                    $0.chatID == chatID
                        && (fullSnapshot || $0.hasPendingMembershipVisibilityRefresh)
                }
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
        conversationStateScopeChanges.send(())
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
        if state.mainUnread != nil { state.mainUnread = nil }
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
        if state.conversationUnreadSummaries != summaries {
            state.conversationUnreadSummaries = summaries
        }
        if payload.full || payload.appBadgeCount != nil {
            let appBadgeCount = payload.appBadgeCount.map { max(0, $0) }
            if state.appBadgeCount != appBadgeCount { state.appBadgeCount = appBadgeCount }
        }
        if payload.full || payload.mainUnread != nil {
            if state.mainUnread != payload.mainUnread { state.mainUnread = payload.mainUnread }
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
            if let fence = readFences[key] {
                if !value.accessible
                    || (payload.full && fence.watchRequestID != payload.requestId)
                {
                    readFences.removeValue(forKey: key)
                } else {
                    guard let cursor = value.lastReadMessageId, cursor >= fence.cursor else {
                        reconcileReadFence(key)
                        continue
                    }
                    readFences.removeValue(forKey: key)
                }
            }
            if var acknowledgement = readAcknowledgements[key] {
                acknowledgement.sawWatchedState = true
                if let cursor = value.lastReadMessageId {
                    acknowledgement.watchedThrough =
                        max(acknowledgement.watchedThrough ?? cursor, cursor)
                    if value.accessible, cursor >= acknowledgement.requestedCursor {
                        clearPendingRead(key, through: cursor)
                    }
                }
                readAcknowledgements[key] = acknowledgement
            }
            rowRevisions[key, default: 0] += 1
            if !value.accessible {
                if historyCache != nil, key.threadID == nil {
                    removeGroupFromLists(chatID: key.chatID)
                    continue
                }
                if deniedReadScopes.insert(key).inserted { invalidatePendingRead(key) }
                confirmedReadCursors.removeValue(forKey: key)
                conversationReadStates.removeValue(forKey: key)
                if key.threadID == nil {
                    if state.chats.contains(where: { $0.id == key.chatID }) {
                        state.chats.removeAll { $0.id == key.chatID }
                    }
                    if state.archivedChats.contains(where: { $0.id == key.chatID }) {
                        state.archivedChats.removeAll { $0.id == key.chatID }
                    }
                } else {
                    if state.threads.contains(where: { $0.conversationKey == key }) {
                        state.threads.removeAll { $0.conversationKey == key }
                    }
                    if state.archivedThreads.contains(where: { $0.conversationKey == key }) {
                        state.archivedThreads.removeAll { $0.conversationKey == key }
                    }
                }
                listStateRevision += 1
            } else {
                deniedReadScopes.remove(key)
            }
            applyReadState(
                .init(
                    lastReadMessageId: value.lastReadMessageId, unreadCount: value.unreadCount,
                    unreadMentions: value.unreadMentions, unreadReactions: value.unreadReactions),
                chatID: key.chatID, threadID: key.threadID, confirmsCursor: value.accessible)
        }
    }

    func conversationReadState(chatID: String, threadID: String?) async throws -> ReadStateResponse
    {
        try await fetchConversationReadState(
            chatID: chatID, threadID: threadID, ignoringWatch: false)
    }

    private func fetchConversationReadState(
        chatID: String, threadID: String?, ignoringWatch: Bool, requireFresh: Bool = false
    ) async throws -> ReadStateResponse {
        guard networkAuthorized else { throw CancellationError() }
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        if !ignoringWatch, conversationStateReady(chatID: chatID, threadID: threadID),
            let cached = conversationReadStates[key]
        {
            return cached
        }
        let revision = rowRevisions[key, default: 0]
        rowRevisions[key] = revision
        let readVersion = readStateVersion
        let scopeReadVersion = readStateVersions[key, default: 0]
        let response = try await performGroupRequest(generation: generation) {
            if let threadID {
                return try await apiClient.threadReadState(chatID: chatID, threadID: threadID)
            }
            return try await apiClient.chatReadState(chatID: chatID)
        }
        guard networkAuthorized, rowRevisions[key, default: 0] == revision, localStateWrites[key] == nil,
            !requireFresh || readStateVersions[key, default: 0] == scopeReadVersion
        else {
            if requireFresh { throw CancellationError() }
            if let cached = conversationReadStates[key] { return cached }
            throw CancellationError()
        }
        let accepted = resolveReadSnapshot(response, key: key, version: readVersion)
        applyReadState(accepted, chatID: chatID, threadID: threadID)
        return accepted
    }

    private func reconcileReadFence(_ key: ConversationKey) {
        guard foregroundActive, readFenceReconciliations.insert(key).inserted else { return }
        // WS invalidations are coalesced, so a later mark-unread/deletion can
        // replace the read acknowledgement. Only a fresh primary read can
        // distinguish that rewind from an older queued state on this scope.
        fallbackConversationStates(key)
    }

    private func fallbackConversationStates(_ key: ConversationKey? = nil) {
        guard foregroundActive, canFetchHistory else { return }
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
                    let reconcileRead = readFenceReconciliations.contains(key)
                    let fenceVersion = readFences[key]?.version
                    _ = try? await fetchConversationReadState(
                        chatID: key.chatID, threadID: key.threadID, ignoringWatch: reconcileRead)
                    guard generation == requestGeneration, refreshGeneration == currentRefresh,
                        stateFallbackGeneration == currentFallback
                    else { return }
                    if reconcileRead {
                        readFenceReconciliations.remove(key)
                        if let currentFence = readFences[key], currentFence.version != fenceVersion
                        {
                            reconcileReadFence(key)
                        }
                    }
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
        chatID: String, threadID: String?, mentions: Bool = true, reactions: Bool = true,
        reactionMessageID: MessageID? = nil
    ) {
        for model in visibleTimelines()
        where model.chatID == chatID && model.threadID == threadID {
            model.refreshUnreadActivity(
                mentions: mentions, reactions: reactions, reactionMessageID: reactionMessageID)
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

    func unreadReactions(chatID: String, threadID: String?, after: String?) async throws
        -> UnreadReactionIDsResponse
    {
        guard foregroundActive else { throw CancellationError() }
        let root = try activityThreadID(threadID)
        return try await performGroupRequest(generation: generation) {
            try await apiClient.unreadReactions(chatID: chatID, threadID: root, after: after)
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
                chatID: chatID, threadID: threadID, confirmsCursor: false)
        } else if threadID == nil, let chat = chat(id: chatID) {
            applyReadState(
                .init(
                    lastReadMessageId: chat.lastReadMessageId, unreadCount: chat.unreadCount,
                    unreadMentions: chat.unreadMentions, unreadReactions: response.unreadReactions),
                chatID: chatID, threadID: nil, confirmsCursor: false)
        } else if let cached = conversationReadStates[key] {
            applyReadState(
                .init(
                    lastReadMessageId: cached.lastReadMessageId, unreadCount: cached.unreadCount,
                    unreadMentions: cached.unreadMentions, unreadReactions: response.unreadReactions
                ),
                chatID: chatID, threadID: threadID, confirmsCursor: false)
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

    /// Feature entry points may open an authorized chat before its list refresh arrives.
    /// Keep the selection resolvable through the same list reducer used by live updates.
    func retainChatForNavigation(_ chat: ChatListItem) {
        guard self.chat(id: chat.id) == nil else { return }
        listStateRevision += 1
        rowRevisions[.init(chatID: chat.id), default: 0] += 1
        install(chat)
    }

    func createGroup(name: String) async throws -> ChatListItem {
        let response = try await performGroupRequest(generation: generation) {
            try await apiClient.createGroup(name: name)
        }
        let chat = ChatListItem(
            id: response.id, name: response.name, unreadCount: 0, archived: false, kind: .group)
        retainChatForNavigation(chat)
        invalidateChatList()
        return chat
    }

    func previewGroupInvite(code: String) async throws -> GroupInvitePreview {
        try await performGroupRequest(generation: generation) {
            try await apiClient.previewGroupInvite(code: code)
        }
    }

    func redeemGroupInvite(code: String) async throws -> ChatListItem {
        let response = try await performGroupRequest(generation: generation) {
            try await apiClient.redeemGroupInvite(code: code)
        }
        acceptGroupInfo(response)
        let chat = groupChatSnapshot(response)
        retainChatForNavigation(chat)
        invalidateChatList()
        return chat
    }

    func speakingMode(chatID: String) -> SpeakingMode? {
        groupInfoByChatID[chatID]?.effectiveSpeakingMode
    }

    /// Membership and kind remain server decisions. A quote is still a main send;
    /// only an actual destination thread changes the speaking action.
    func requireSpeakingPermission(chatID: String, threadID: String?, freshThread: Bool = false) async throws {
        let requestGeneration = generation
        // A loaded DM row already authorizes its kind; speaking policy never
        // changes direct-message authorization or requires a group-info preflight.
        if !freshThread, chat(id: chatID)?.kind == .dm { return }
        let info: GroupInfoResponse
        if let cached = groupInfoByChatID[chatID], !groupInfoInvalidations.contains(chatID) {
            info = cached
        } else {
            info = try await groupInfo(chatID: chatID)
        }
        guard generation == requestGeneration else { throw CancellationError() }
        guard !groupInfoInvalidations.contains(chatID) else {
            throw SpeakingWriteError.unavailable
        }
        guard info.kind == .group else { return }
        if info.myRole == .admin { return }
        guard info.myRole != nil, let mode = info.effectiveSpeakingMode else {
            throw SpeakingWriteError.unavailable
        }
        if let threadID {
            guard let rootID = MessageID(threadID) else { throw SpeakingWriteError.unavailable }
            if mode == .readOnly { throw SpeakingWriteError.restricted(mode) }
            if mode == .repliesOnly {
                let exists: Bool
                if !freshThread, let cached = cachedThreadExistence(chatID: chatID, rootID: rootID) {
                    exists = cached
                } else {
                    let root = try await forwardSourceMessage(chatID: chatID, messageID: rootID)
                    guard generation == requestGeneration else { throw CancellationError() }
                    guard root.chatId == chatID, root.id == rootID, root.replyRootId == nil, !root.isDeleted else {
                        throw SpeakingWriteError.unavailable
                    }
                    exists = root.threadInfo != nil
                    if exists {
                        confirmedThreadRoots.insert(.init(chatID: chatID, threadID: threadID))
                    }
                }
                if groupInfoInvalidations.contains(chatID)
                    || groupInfoByChatID[chatID]?.effectiveSpeakingMode != mode
                {
                    try await requireSpeakingPermission(chatID: chatID, threadID: threadID, freshThread: freshThread)
                    return
                }
                guard groupInfoByChatID[chatID]?.myRole != nil else {
                    throw SpeakingWriteError.unavailable
                }
                guard exists else { throw SpeakingWriteError.restricted(mode) }
            }
        } else if !mode.allowsMainMessages {
            throw SpeakingWriteError.restricted(mode)
        }
        guard generation == requestGeneration else { throw CancellationError() }
    }

    /// Only an actual root's threadInfo proves existence. Reply counts and
    /// preview records are not substitutes, including when the count is zero.
    private func cachedThreadExistence(chatID: String, rootID: MessageID) -> Bool? {
        let key = ConversationKey(chatID: chatID, threadID: rootID.description)
        if confirmedThreadRoots.contains(key) { return true }
        var sawRoot = false
        for timeline in timelines.values {
            guard let model = timeline.value, model.chatID == chatID else { continue }
            for row in model.rows {
                guard case .message(let row) = row, let message = row.entry.remoteMessage,
                    message.chatId == chatID, message.id == rootID, message.replyRootId == nil
                else { continue }
                if message.threadInfo != nil {
                    confirmedThreadRoots.insert(key)
                    return true
                }
                sawRoot = true
            }
        }
        return sawRoot ? false : nil
    }

    private func effectiveSpeakingMode(
        group: SpeakingMode?, personal: SpeakingMode?, role: GroupRole?
    ) -> SpeakingMode? {
        guard let role else { return nil }
        if role == .admin { return .unrestricted }
        guard let group, let personal else { return nil }
        func rank(_ mode: SpeakingMode) -> Int {
            switch mode {
            case .unrestricted: 0
            case .threadsOnly: 1
            case .repliesOnly: 2
            case .readOnly: 3
            }
        }
        return rank(group) >= rank(personal) ? group : personal
    }

    func currentSavedSendDecision(for key: ConversationKey) -> Bool? {
        historyCache?.accessRevoked(key.chatID) == true ? false : savedSendDecisions[key]
    }

    func savedSendDecision(for key: ConversationKey) async -> Bool? {
        if let decision = currentSavedSendDecision(for: key) { return decision }
        guard let historyCache, historyCache.isAvailable, sendPermissionVersions[key.chatID] == nil else { return nil }
        let current = generation
        let peerVersion = peerPermissionVersion
        do {
            let context = try await historyCache.read { try await $0.cachedScopeContext(key) }
            guard current == generation, peerVersion == peerPermissionVersion,
                sendPermissionVersions[key.chatID] == nil, !Task.isCancelled
            else { return nil }
            if let decision = currentSavedSendDecision(for: key) { return decision }
            guard let decision = context?.canSend else { return nil }
            sendPermissionPeers[key.chatID] = context?.sendPeerUID
            savedSendDecisions[key] = decision
            return decision
        } catch { return nil }
    }

    func rememberSendDecision(_ allowed: Bool, for key: ConversationKey) {
        guard canFetchHistory, historyCache?.accessRevoked(key.chatID) != true else { return }
        if !allowed { dispatchPermissionChecks.remove(key) }
        let peer = groupInfoByChatID[key.chatID]?.peer?.uid ?? chat(id: key.chatID)?.peer?.uid
        guard savedSendDecisions[key] != allowed || sendPermissionPeers[key.chatID] != peer else { return }
        sendPermissionPeers[key.chatID] = peer
        savedSendDecisions[key] = allowed
        historyCache?.submit(required: !allowed) { store, epoch in
            try await store.cacheSendDecision(allowed, in: key, peerUID: peer, epoch: epoch)
        }
    }

    func hasCurrentGroupWriteInfo(chatID: String) -> Bool {
        groupInfoByChatID[chatID] != nil && !groupInfoInvalidations.contains(chatID)
            && historyCache?.accessRevoked(chatID) != true
    }

    func savedCompleteThread(chatID: String, rootID: MessageID, limit: Int) async throws -> [MessageResponse] {
        guard let historyCache, !historyCache.accessRevoked(chatID) else {
            throw ForwardDestinationPicker.SourceError.unavailable
        }
        let key = ConversationKey(chatID: chatID, threadID: rootID.description)
        guard let messages = try await historyCache.read({ try await $0.completeCachedThread(key, limit: limit) }),
            !historyCache.accessRevoked(chatID)
        else { throw ForwardDestinationPicker.SourceError.unavailable }
        guard messages.count <= limit else { throw ForwardDestinationPicker.SourceError.tooMany }
        return messages
    }

    func prepareForwardDestination(_ key: ConversationKey) async throws {
        guard historyCache != nil else {
            try await requireSpeakingPermission(chatID: key.chatID, threadID: key.threadID)
            return
        }
        if await savedSendDecision(for: key) == true { return }
        guard canFetchHistory else { throw SpeakingWriteError.unavailable }
        try await checkDestinationWrite(key)
    }

    private func authorizeEnqueue(_ key: ConversationKey) async throws {
        let current = generation
        try await prepareForwardDestination(key)
        guard current == generation, currentSavedSendDecision(for: key) == true, !Task.isCancelled
        else { throw SpeakingWriteError.unavailable }
    }

    struct SendPermissionStamp: Equatable {
        fileprivate let session: Int
        let network: Int
        fileprivate let permission: Int
        fileprivate let peer: Int
    }

    func sendPermissionStamp(for key: ConversationKey) -> SendPermissionStamp {
        .init(session: generation, network: readNetworkVersion,
            permission: sendPermissionVersions[key.chatID, default: 0], peer: peerPermissionVersion)
    }

    func rememberVerifiedSendPermission(for key: ConversationKey, stamp: SendPermissionStamp) {
        guard canFetchHistory, !Task.isCancelled, stamp == sendPermissionStamp(for: key),
            hasCurrentGroupWriteInfo(chatID: key.chatID)
        else { return }
        dispatchPermissionChecks.insert(key)
        rememberSendDecision(true, for: key)
    }

    private func authorizeDispatch(_ key: ConversationKey) async throws {
        guard canFetchHistory else { throw CancellationError() }
        guard historyCache?.accessRevoked(key.chatID) != true else { throw SpeakingWriteError.unavailable }
        if !dispatchPermissionChecks.contains(key) {
            try await checkDestinationWrite(key)
            guard dispatchPermissionChecks.contains(key) else { throw CancellationError() }
        }
    }

    private func checkDestinationWrite(_ key: ConversationKey) async throws {
        let current = generation
        let network = readNetworkVersion
        guard canFetchHistory, historyCache?.accessRevoked(key.chatID) != true else {
            throw SpeakingWriteError.unavailable
        }
        do {
            let info = try await groupInfo(chatID: key.chatID)
            let stamp = sendPermissionStamp(for: key)
            if info.kind == .dm {
                guard info.myRole != nil, let peer = info.peer else { throw SpeakingWriteError.unavailable }
                let relationship = try await friendRelationship(peerUID: peer.uid)
                guard stamp == sendPermissionStamp(for: key) else { throw CancellationError() }
                guard relationship.canDm, relationship.blocking != true, relationship.blockedBy != true,
                    relationship.dmChatId == nil || relationship.dmChatId == key.chatID
                else { throw SpeakingWriteError.unavailable }
            } else {
                try await requireSpeakingPermission(chatID: key.chatID, threadID: key.threadID, freshThread: true)
            }
            guard current == generation, network == readNetworkVersion,
                stamp == sendPermissionStamp(for: key), canFetchHistory, !Task.isCancelled,
                hasCurrentGroupWriteInfo(chatID: key.chatID)
            else { throw CancellationError() }
            rememberVerifiedSendPermission(for: key, stamp: stamp)
        } catch {
            guard current == generation else { throw CancellationError() }
            if error is SpeakingWriteError { rememberSendDecision(false, for: key) }
            throw error
        }
    }

    private func invalidateSendPermissions(chatID: String) {
        sendPermissionVersions[chatID, default: 0] &+= 1
        if savedSendDecisions.keys.contains(where: { $0.chatID == chatID }) {
            savedSendDecisions = savedSendDecisions.filter { $0.key.chatID != chatID }
        }
        dispatchPermissionChecks = dispatchPermissionChecks.filter { $0.chatID != chatID }
        historyCache?.submit(required: true) {
            try await $0.invalidateSendDecisions(chatID: chatID, epoch: $1)
        }
    }

    private func invalidateSendPermissions(peerUID: Int32) {
        peerPermissionVersion &+= 1
        for (chatID, peer) in sendPermissionPeers where peer == peerUID { invalidateSendPermissions(chatID: chatID) }
        historyCache?.submit(required: true) {
            try await $0.invalidateSendDecisions(peerUID: peerUID, epoch: $1)
        }
    }

    private func acceptGroupSpeakingMode(_ response: GroupSpeakingModeResponse) {
        invalidateSendPermissions(chatID: response.chatId)
        groupInfoRevisions[response.chatId, default: 0] += 1
        groupSpeakingRevisions[response.chatId, default: 0] += 1
        if let info = groupInfoByChatID[response.chatId] {
            groupInfoByChatID[response.chatId] = info.withSpeakingState(
                speakingMode: response.speakingMode, mySpeakingMode: info.mySpeakingMode,
                effectiveSpeakingMode: effectiveSpeakingMode(
                    group: response.speakingMode, personal: info.mySpeakingMode, role: info.myRole),
                myRole: info.myRole)
        } else {
            groupInfoInvalidations.insert(response.chatId)
            scheduleRecovery(chatID: response.chatId, membershipOnly: true)
        }
    }

    private func acceptMemberSpeakingMode(_ response: MemberSpeakingModeResponse) {
        memberSpeakingRevisions[response.chatId, default: [:]][response.uid, default: 0] += 1
        memberSpeakingModesByChatID[response.chatId, default: [:]][response.uid] = response
        guard response.uid == currentUserProfile?.uid else { return }
        invalidateSendPermissions(chatID: response.chatId)
        groupInfoRevisions[response.chatId, default: 0] += 1
        if let info = groupInfoByChatID[response.chatId] {
            if info.speakingMode != response.groupSpeakingMode {
                groupSpeakingRevisions[response.chatId, default: 0] += 1
            }
            groupInfoByChatID[response.chatId] = info.withSpeakingState(
                speakingMode: response.groupSpeakingMode, mySpeakingMode: response.speakingMode,
                effectiveSpeakingMode: response.effectiveSpeakingMode, myRole: response.role)
            if info.myRole != response.role {
                membershipPolicyRevisions[response.chatId, default: 0] += 1
                conversationMessages.invalidateMembershipSnapshots(chatID: response.chatId)
                groupInfoInvalidations.insert(response.chatId)
                invalidateMembershipVisibility(chatID: response.chatId)
            }
        } else {
            groupInfoInvalidations.insert(response.chatId)
            scheduleRecovery(chatID: response.chatId, membershipOnly: true)
        }
    }

    private func memberSpeakingSnapshot(_ member: MemberResponse, chatID: String)
        -> MemberSpeakingModeResponse?
    {
        guard let groupMode = groupInfoByChatID[chatID]?.speakingMode,
            let personal = member.speakingMode,
            let effective = effectiveSpeakingMode(
                group: groupMode, personal: personal, role: member.role)
        else { return nil }
        return .init(
            chatId: chatID, uid: member.uid, role: member.role, speakingMode: personal,
            groupSpeakingMode: groupMode, effectiveSpeakingMode: effective)
    }

    private func acceptGroupInfo(_ info: GroupInfoResponse) {
        if info.myRole != nil { historyCache?.confirmAccess(info.id) }
        if let previous = groupInfoByChatID[info.id],
            previous.myRole != info.myRole || previous.effectiveSpeakingMode != info.effectiveSpeakingMode
        {
            invalidateSendPermissions(chatID: info.id)
        } else if info.kind == .group, info.myRole == nil {
            invalidateSendPermissions(chatID: info.id)
        }
        groupInfoRevisions[info.id, default: 0] += 1
        if groupInfoByChatID[info.id]?.speakingMode != info.speakingMode {
            groupSpeakingRevisions[info.id, default: 0] += 1
        }
        groupInfoByChatID[info.id] = info
        groupInfoInvalidations.remove(info.id)
        if let uid = currentUserProfile?.uid {
            if let role = info.myRole, let personal = info.mySpeakingMode,
                let group = info.speakingMode, let effective = info.effectiveSpeakingMode
            {
                let member = MemberSpeakingModeResponse(
                    chatId: info.id, uid: uid, role: role, speakingMode: personal,
                    groupSpeakingMode: group, effectiveSpeakingMode: effective)
                if memberSpeakingModesByChatID[info.id]?[uid] != member {
                    memberSpeakingRevisions[info.id, default: [:]][uid, default: 0] += 1
                    memberSpeakingModesByChatID[info.id, default: [:]][uid] = member
                }
            } else if info.myRole == nil {
                memberSpeakingRevisions[info.id, default: [:]][uid, default: 0] += 1
                memberSpeakingModesByChatID[info.id]?.removeValue(forKey: uid)
            }
        }
        if let policy = info.membershipMessagePolicy {
            acceptMembershipPolicy(policy, chatID: info.id)
        }
    }

    private func acceptChatSettings(_ settings: ChatSettings) {
        guard membershipChatSettings != settings else { return }
        if networkAuthorized { historyCache?.invalidatePolicy(settings: settings) }
        let membershipChanged =
            membershipChatSettings?.showMembershipMessages != settings.showMembershipMessages
        membershipChatSettings = settings
        membershipSettingsRevision += 1
        if currentUserProfile?.showMembershipMessages != settings.showMembershipMessages
            || currentUserProfile?.showUnreadMessageCount != settings.showUnreadMessageCount
        {
            currentUserProfile = currentUserProfile?.withChatSettings(settings)
        }
        conversationMessages.setMembershipSettings(settings)
        if membershipChanged { invalidateMembershipVisibility() }
    }

    private func acceptMembershipPolicy(_ policy: MembershipMessagePolicy, chatID: String) {
        guard membershipPolicies[chatID] != policy else { return }
        historyCache?.invalidatePolicy(chatID: chatID, policy: policy)
        membershipPolicies[chatID] = policy
        membershipPolicyRevisions[chatID, default: 0] += 1
        if let info = groupInfoByChatID[chatID] {
            groupInfoByChatID[chatID] = info.withMembershipMessagePolicy(policy)
        }
        conversationMessages.setMembershipPolicy(policy, chatID: chatID)
        invalidateMembershipVisibility(chatID: chatID)
    }

    private func displayFilteredSnapshot(_ chat: ChatListItem) -> ChatListItem {
        var chat = membershipPolicies[chat.id].map { chat.withMembershipMessagePolicy($0) } ?? chat
        if let preview = chat.lastMessage {
            let redacted = redactingDeletedPreview(preview, chatID: chat.id)
            if redacted != preview { chat = chat.withPreview(redacted) }
        }
        guard chat.kind == .group, chat.lastMessage?.systemKind?.isMembership == true,
            conversationMessages.hidesMembershipMessages(chatID: chat.id)
                || chat.membershipMessagePolicy?.canView == false
        else { return chat }
        return chat.withPreview(nil, preserveActivity: true)
    }

    private func displayFilteredSnapshot(_ thread: ThreadListItem) -> ThreadListItem {
        let hidesMembership = thread.chatKind == .group
            && conversationMessages.hidesMembershipMessages(chatID: thread.chatId)
        let root = hidesMembership && thread.threadRootMessage.systemKind?.isMembership == true
            ? thread.threadRootMessage.redactedForDeletion()
            : redactingDeletedPreview(thread.threadRootMessage, chatID: thread.chatId)
        let reply = hidesMembership && thread.lastReply?.systemKind?.isMembership == true
            ? nil : thread.lastReply.map { redactingDeletedPreview($0, chatID: thread.chatId) }
        guard root != thread.threadRootMessage || reply != thread.lastReply else { return thread }
        return thread.withActivity(root: root, lastReply: reply)
    }

    private func invalidateMembershipVisibility(chatID: String? = nil) {
        listStateRevision += 1
        dirtyLists.formUnion([.chats, .archivedChats].filter { refreshTasks[$0] != nil })
        var chatIDs = Set(
            (state.chats + state.archivedChats).filter {
                $0.kind == .group && (chatID == nil || $0.id == chatID)
            }.map(\.id))
        chatIDs.formUnion(
            visibleTimelines().filter {
                $0.isGroupChat && $0.threadID == nil && (chatID == nil || $0.chatID == chatID)
            }.map(\.chatID))
        if let chatID { chatIDs.insert(chatID) }
        state.chats = state.chats.map(displayFilteredSnapshot)
        state.archivedChats = state.archivedChats.map(displayFilteredSnapshot)
        state.threads = state.threads.map(displayFilteredSnapshot)
        state.archivedThreads = state.archivedThreads.map(displayFilteredSnapshot)
        invalidateConversationWatches()
        for id in chatIDs {
            let key = ConversationKey(chatID: id)
            reconcileRow(key)
            fallbackConversationStates(key)
            scheduleRecovery(chatID: id, membershipOnly: true)
        }
    }

    func updateChatSettings(
        showMembershipMessages: Bool? = nil, showUnreadMessageCount: Bool? = nil
    ) async throws -> ChatSettings {
        let requestGeneration = generation
        membershipSettingsWrites += 1
        membershipSettingsRevision += 1
        if showMembershipMessages != nil {
            conversationMessages.invalidateMembershipSnapshots()
            invalidateMembershipVisibility()
        }
        defer {
            if generation == requestGeneration {
                membershipSettingsWrites -= 1
                membershipSettingsRevision += 1
                if showMembershipMessages != nil {
                    conversationMessages.invalidateMembershipSnapshots()
                    invalidateMembershipVisibility()
                }
            }
        }
        return try await serializeGroupMutation(chatID: "\0membership-settings") {
            let response = try await self.performGroupRequest(generation: requestGeneration) {
                try await self.apiClient.updateChatSettings(
                    .init(
                        showMembershipMessages: showMembershipMessages,
                        showUnreadMessageCount: showUnreadMessageCount))
            }
            self.acceptChatSettings(response)
            return response
        }
    }

    func updateGroupSpeakingMode(chatID: String, speakingMode: SpeakingMode) async throws
        -> GroupSpeakingModeResponse
    {
        let requestGeneration = generation
        return try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            self.groupInfoRevisions[chatID, default: 0] += 1
            self.groupSpeakingRevisions[chatID, default: 0] += 1
            let revision = self.groupSpeakingRevisions[chatID, default: 0]
            let response = try await self.performGroupRequest(generation: requestGeneration) {
                try await self.apiClient.updateGroupSpeakingMode(
                    chatID: chatID, speakingMode: speakingMode)
            }
            guard response.chatId == chatID else { throw APIError.unexpectedResponse }
            if self.groupSpeakingRevisions[chatID, default: 0] == revision {
                self.acceptGroupSpeakingMode(response)
            }
            return .init(
                chatId: chatID,
                speakingMode: self.groupInfoByChatID[chatID]?.speakingMode ?? response.speakingMode)
        }
    }

    func updateMemberSpeakingMode(chatID: String, uid: Int32, speakingMode: SpeakingMode)
        async throws -> MemberSpeakingModeResponse
    {
        let requestGeneration = generation
        return try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            if uid == self.currentUserProfile?.uid {
                self.groupInfoRevisions[chatID, default: 0] += 1
            }
            self.memberSpeakingRevisions[chatID, default: [:]][uid, default: 0] += 1
            let revision = self.memberSpeakingRevisions[chatID]?[uid, default: 0] ?? 0
            let response = try await self.performGroupRequest(generation: requestGeneration) {
                try await self.apiClient.updateMemberSpeakingMode(
                    chatID: chatID, uid: uid, speakingMode: speakingMode)
            }
            guard response.chatId == chatID, response.uid == uid else {
                throw APIError.unexpectedResponse
            }
            if self.memberSpeakingRevisions[chatID]?[uid, default: 0] == revision {
                let member = MemberResponse(
                    uid: uid, role: response.role, speakingMode: response.speakingMode)
                self.acceptMemberSpeakingMode(
                    self.memberSpeakingSnapshot(member, chatID: chatID) ?? response)
            }
            return self.memberSpeakingModesByChatID[chatID]?[uid] ?? response
        }
    }

    func groupChatSnapshot(_ info: GroupInfoResponse) -> ChatListItem {
        chat(id: info.id)
            ?? ChatListItem(
                id: info.id, name: info.name, avatar: info.avatar, unreadCount: 0,
                archived: false, kind: info.kind, peer: info.peer,
                membershipMessagePolicy: info.membershipMessagePolicy)
    }

    func listGroupInvites(chatID: String) async throws -> GroupInvitesPage {
        try await performGroupRequest(generation: generation) {
            try await apiClient.listGroupInvites(chatID: chatID)
        }
    }

    func createGroupInvite(body: CreateGroupInviteBody) async throws -> GroupInvite {
        try await performGroupRequest(generation: generation) {
            try await apiClient.createGroupInvite(body: body)
        }
    }

    func revokeGroupInvite(id: String) async throws {
        try await performGroupRequest(generation: generation) {
            try await apiClient.revokeGroupInvite(id: id)
        }
    }

    func sendGroupInvite(body: SendGroupInviteBody) async throws {
        let requestGeneration = generation
        try await requireSpeakingPermission(chatID: body.destinationChatId, threadID: nil)
        _ = try await performGroupRequest(generation: requestGeneration) {
            try await apiClient.sendGroupInvite(body: body)
        }
    }

    func updateGroup(chatID: String, body: UpdateGroupBody) async throws -> GroupInfoResponse {
        let requestGeneration = generation
        return try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            self.groupInfoRevisions[chatID, default: 0] += 1
            self.membershipPolicyRevisions[chatID, default: 0] += 1
            self.conversationMessages.invalidateMembershipSnapshots(chatID: chatID)
            let revision = self.groupInfoRevisions[chatID, default: 0]
            let policyRevision = self.membershipPolicyRevisions[chatID, default: 0]
            var response = try await self.performGroupRequest(generation: requestGeneration) {
                try await self.apiClient.updateGroup(chatID: chatID, body: body)
            }
            guard response.id == chatID else { throw APIError.unexpectedResponse }
            if self.groupInfoRevisions[chatID, default: 0] != revision {
                guard let current = self.groupInfoByChatID[chatID] else {
                    throw CancellationError()
                }
                response = response.withSpeakingState(
                    speakingMode: current.speakingMode, mySpeakingMode: current.mySpeakingMode,
                    effectiveSpeakingMode: current.effectiveSpeakingMode, myRole: current.myRole)
            }
            if self.membershipPolicyRevisions[chatID, default: 0] != policyRevision {
                response = response.withMembershipMessagePolicy(self.membershipPolicies[chatID])
            }
            let needsPolicyRefresh = self.groupInfoInvalidations.contains(chatID)
            self.acceptGroupInfo(response)
            if needsPolicyRefresh {
                self.groupInfoInvalidations.insert(chatID)
                self.scheduleRecovery(chatID: chatID, membershipOnly: true)
            }
            self.invalidateMembershipVisibility(chatID: chatID)
            self.invalidateChatList()
            return self.groupInfoByChatID[chatID] ?? response
        }
    }

    func groupAvatarUpload(
        chatID: String, filename: String, contentType: String, size: Int64,
        width: Int, height: Int
    ) async throws -> GroupAvatarUpload {
        try await performGroupRequest(generation: generation) {
            try await apiClient.groupAvatarUpload(
                chatID: chatID, filename: filename,
                contentType: contentType, size: size, width: width, height: height)
        }
    }

    func groupInfo(chatID: String) async throws -> GroupInfoResponse {
        let requestGeneration = generation
        let revision = groupInfoRevisions[chatID, default: 0]
        let policyRevision = membershipPolicyRevisions[chatID, default: 0]
        groupInfoReadSequences[chatID, default: 0] += 1
        let readSequence = groupInfoReadSequences[chatID, default: 0]
        let response: GroupInfoResponse
        do {
            response = try await performGroupRequest(generation: requestGeneration) {
                try await apiClient.groupInfo(chatID: chatID)
            }
        } catch let error as APIError {
            if generation == requestGeneration, groupInfoRevisions[chatID, default: 0] == revision,
                groupInfoReadSequences[chatID, default: 0] == readSequence
            {
                switch error {
                case .http(status: 403, body: _), .http(status: 404, body: _),
                    .invalidResponse(statusCode: 403), .invalidResponse(statusCode: 404):
                    removeGroupFromLists(chatID: chatID)
                default: break
                }
            }
            throw error
        }
        guard response.id == chatID else { throw APIError.unexpectedResponse }
        if groupInfoRevisions[chatID, default: 0] != revision
            || groupInfoReadSequences[chatID, default: 0] != readSequence
            || membershipPolicyRevisions[chatID, default: 0] != policyRevision
        {
            guard let current = groupInfoByChatID[chatID] else { throw CancellationError() }
            return current
        }
        acceptGroupInfo(response)
        return response
    }

    func groupMembers(chatID: String, query: ListMembersQuery) async throws -> ListMembersResponse {
        let requestGeneration = generation
        let revisions = memberSpeakingRevisions[chatID, default: [:]]
        let groupRevision = groupInfoRevisions[chatID, default: 0]
        let response = try await performGroupRequest(generation: requestGeneration) {
            try await apiClient.listMembers(chatID: chatID, query: query)
        }
        guard groupInfoRevisions[chatID, default: 0] == groupRevision else { return response }
        for member in response.members
        where (memberSpeakingRevisions[chatID]?[member.uid, default: 0] ?? 0)
            == revisions[member.uid, default: 0]
        {
            if let snapshot = memberSpeakingSnapshot(member, chatID: chatID),
                memberSpeakingModesByChatID[chatID]?[member.uid] != snapshot
            {
                acceptMemberSpeakingMode(snapshot)
            }
        }
        return response
    }

    func updateGroupMemberRole(chatID: String, uid: Int32, role: GroupRole) async throws
        -> MemberResponse
    {
        let requestGeneration = generation
        return try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            if uid == self.currentUserProfile?.uid {
                self.groupInfoRevisions[chatID, default: 0] += 1
            }
            self.memberSpeakingRevisions[chatID, default: [:]][uid, default: 0] += 1
            let revision = self.memberSpeakingRevisions[chatID]?[uid, default: 0] ?? 0
            let member = try await self.performGroupRequest(generation: requestGeneration) {
                try await self.apiClient.updateGroupMemberRole(chatID: chatID, uid: uid, role: role)
            }
            guard member.uid == uid else { throw APIError.unexpectedResponse }
            if self.memberSpeakingRevisions[chatID]?[uid, default: 0] == revision {
                if let snapshot = self.memberSpeakingSnapshot(member, chatID: chatID) {
                    self.acceptMemberSpeakingMode(snapshot)
                } else {
                    self.memberSpeakingModesByChatID[chatID]?.removeValue(forKey: uid)
                    self.groupInfoInvalidations.insert(chatID)
                    self.scheduleRecovery(chatID: chatID, membershipOnly: true)
                }
            }
            self.invalidateChatList()
            if let latest = self.memberSpeakingModesByChatID[chatID]?[uid] {
                return .init(
                    uid: uid, username: member.username, avatarUrl: member.avatarUrl,
                    role: latest.role, speakingMode: latest.speakingMode)
            }
            return member
        }
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

    @discardableResult
    func setNotificationSetting(chatID: String, request: UpdateNotificationSettingRequest)
        async throws
        -> ChatNotificationSettingResponse
    {
        let requestGeneration = generation
        return try await serializeGroupMutation(chatID: chatID) {
            guard self.generation == requestGeneration else { throw CancellationError() }
            let key = ConversationKey(chatID: chatID)
            self.beginLocalStateWrite(key)
            defer { self.finishLocalStateWrite(key, generation: requestGeneration) }
            self.notificationRevision += 1
            let revision = self.notificationRevision
            self.notificationVersions[chatID] = revision
            let previous = self.chat(id: chatID)
            if let previous {
                let override: Bool? =
                    switch request.mode {
                    case .inherit: nil
                    case .alwaysMuted: true
                    case .alwaysUnmuted: false
                    case .temporarilyMuted: previous.muteOverride
                    }
                let until =
                    request.mode == .temporarilyMuted
                    ? Date().addingTimeInterval(TimeInterval(request.durationSeconds ?? 0)) : nil
                let muted =
                    (until.map { $0 > Date() } ?? false)
                    || (override ?? self.state.notificationDefaults?.mutedByDefault(
                        kind: previous.kind) ?? false)
                self.acceptNotificationSetting(
                    .init(
                        chatId: chatID, kind: previous.kind, archived: previous.archived,
                        muteOverride: override, mutedUntil: until, isMuted: muted))
            }
            do {
                let response = try await self.performGroupRequest(generation: requestGeneration) {
                    try await self.apiClient.updateChatNotificationSetting(
                        chatID: chatID, request: request)
                }
                guard response.chatId == chatID else { throw APIError.unexpectedResponse }
                if self.notificationVersions[chatID] == revision {
                    self.acceptNotificationSetting(response)
                }
                return self.notificationSnapshots[chatID] ?? response
            } catch {
                if self.generation == requestGeneration,
                    self.notificationVersions[chatID] == revision,
                    let previous
                {
                    self.acceptNotificationSetting(
                        .init(
                            chatId: chatID, kind: previous.kind, archived: previous.archived,
                            muteOverride: previous.muteOverride, mutedUntil: previous.mutedUntil,
                            isMuted: previous.notificationMuted(
                                defaults: self.state.notificationDefaults)))
                }
                throw error
            }
        }
    }

    func loadNotificationDefaults() async throws {
        defaultsLoadRequested = true
        guard !notificationDefaultsSaving else { return }
        if let defaultsLoadTask {
            try await defaultsLoadTask.value
            return
        }
        let requestGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == requestGeneration { self.defaultsLoadTask = nil }
            }
            while self.defaultsLoadRequested, !self.notificationDefaultsSaving {
                self.defaultsLoadRequested = false
                let revision = self.defaultsRevision
                let response = try await self.performGroupRequest(generation: requestGeneration) {
                    try await self.apiClient.notificationSettings()
                }
                if self.notificationDefaultsSaving {
                    self.defaultsLoadRequested = true
                    return
                }
                guard revision == self.defaultsRevision else { continue }
                self.defaultsRevision += 1
                self.state.notificationDefaults = response
                self.notificationPreferenceChanges.send()
            }
        }
        defaultsLoadTask = task
        try await task.value
    }

    func setNotificationDefault(kind: ChatKind, muted: Bool) async throws {
        guard !notificationDefaultsSaving else { return }
        notificationDefaultsSaving = true
        let requestGeneration = generation
        defaultsRevision += 1
        let revision = defaultsRevision
        let previous = state.notificationDefaults
        if let previous {
            state.notificationDefaults = .init(
                muteGroupChatsByDefault: kind == .group ? muted : previous.muteGroupChatsByDefault,
                muteDirectChatsByDefault: kind == .dm ? muted : previous.muteDirectChatsByDefault)
        }
        defer {
            if generation == requestGeneration {
                notificationDefaultsSaving = false
                if defaultsLoadRequested {
                    Task { try? await loadNotificationDefaults() }
                }
            }
        }
        do {
            let response = try await performGroupRequest(generation: requestGeneration) {
                try await apiClient.updateNotificationSettings(.init(kind: kind, muted: muted))
            }
            guard defaultsRevision == revision else { return }
            state.notificationDefaults = response
            listStateRevision += 1
            notificationPreferenceChanges.send()
        } catch {
            if generation == requestGeneration, defaultsRevision == revision {
                state.notificationDefaults = previous
            }
            throw error
        }
    }

    func notificationExceptions(kind: ChatKind, after: String?) async throws
        -> NotificationExceptionsResponse
    {
        try await performGroupRequest(generation: generation) {
            try await apiClient.notificationExceptions(kind: kind, after: after)
        }
    }

    func clearNotificationExceptions(kind: ChatKind) async throws {
        let revision = notificationRevision
        let response = try await performGroupRequest(generation: generation) {
            try await apiClient.clearNotificationExceptions(kind: kind)
        }
        acceptClearedNotificationExceptions(response, before: revision)
    }

    private func acceptClearedNotificationExceptions(
        _ payload: NotificationExceptionsCleared, before revision: Int? = nil
    ) {
        for chatID in payload.chatIds {
            if let revision, notificationVersions[chatID, default: 0] > revision { continue }
            notificationRevision += 1
            notificationVersions[chatID] = notificationRevision
            if let chat = chat(id: chatID) {
                acceptNotificationSetting(
                    .init(
                        chatId: chatID, kind: payload.kind, archived: chat.archived,
                        isMuted: state.notificationDefaults?.mutedByDefault(kind: payload.kind)
                            ?? false))
            } else if let previous = notificationSnapshots[chatID] {
                acceptNotificationSetting(
                    .init(
                        chatId: chatID, kind: payload.kind, archived: previous.archived,
                        isMuted: state.notificationDefaults?.mutedByDefault(kind: payload.kind)
                            ?? false))
            }
        }
        notificationPreferenceChanges.send()
    }

    private func acceptNotificationSetting(_ response: ChatNotificationSettingResponse) {
        notificationSnapshots[response.chatId] = response
        if let current = chat(id: response.chatId) {
            // Notification snapshots must not roll back an independent archive mutation.
            install(
                current.withNotificationState(
                    mutedUntil: response.mutedUntil, muteOverride: response.muteOverride,
                    isMuted: response.isMuted, archived: current.archived))
        }
        listStateRevision += 1
        rowRevisions[.init(chatID: response.chatId), default: 0] += 1
        scheduleNotificationExpiry()
        notificationPreferenceChanges.send()
    }

    func searchMembers(chatID: String, query: ListMembersQuery) async throws -> [MemberResponse] {
        let response = try await groupMembers(chatID: chatID, query: query)
        return response.members
    }

    private func removeGroupFromLists(chatID: String) {
        historyCache?.revoke(chatID)
        pendingReadChatVersions[chatID, default: 0] += 1
        _ = historyCache?.accessPendingReads { try await $0.clearPendingReads(chatID: chatID) }
        confirmedReadCursors = confirmedReadCursors.filter { $0.key.chatID != chatID }
        pendingReadWakes = pendingReadWakes.filter { $0.chatID != chatID }
        invalidateSendPermissions(chatID: chatID)
        for model in visibleTimelines() where model.chatID == chatID { model.invalidateCachedHistory() }
        confirmedThreadRoots.removeAll()
        groupInfoRevisions[chatID, default: 0] += 1
        membershipPolicyRevisions[chatID, default: 0] += 1
        conversationMessages.invalidateMembershipSnapshots(chatID: chatID)
        groupInfoByChatID.removeValue(forKey: chatID)
        memberSpeakingModesByChatID.removeValue(forKey: chatID)
        groupInfoInvalidations.remove(chatID)
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

    func chatAttachments(chatID: String, kind: ChatAttachmentKind, before: MessageID?)
        async throws -> ListChatAttachmentsResponse
    {
        try await performGroupRequest(generation: generation) {
            try await apiClient.listChatAttachments(chatID: chatID, kind: kind, before: before)
        }
    }

    func browseChatThreads(chatID: String, cursor: MessageID?) async throws
        -> ListChatThreadsResponse
    {
        try await performGroupRequest(generation: generation) {
            try await apiClient.listChatThreads(
                chatID: chatID, query: .init(limit: 20, cursor: cursor, order: .newest))
        }
    }

    func threadParticipants(chatID: String, threadID: String, cursor: Int32?) async throws
        -> ListThreadParticipantsResponse
    {
        try await performGroupRequest(generation: generation) {
            try await apiClient.listThreadParticipants(
                chatID: chatID, threadID: threadID, query: .init(limit: 100, cursor: cursor))
        }
    }

    func isPublishedReadTarget(_ message: MessageResponse) -> Bool {
        outgoingQueue.forwardPlaceholderReason(for: message, merging: false) == nil
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
        try await fetchMessages(chatID: chatID, query: query, ignoringPath: false)
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery, ignoringPath: Bool) async throws
        -> ListMessagesResponse
    {
        guard networkAuthorized && (ignoringPath || canFetchHistory),
            historyCache?.accessRevoked(chatID) != true
        else { throw CancellationError() }
        let requestGeneration = generation
        let cacheRevision = historyCache?.revision
        let tracksVisibility =
            query.threadID == nil
            && chat(id: chatID)?.kind != .dm && groupInfoByChatID[chatID]?.kind != .dm
            && !timelines.values.contains {
                $0.value?.chatID == chatID && $0.value?.isGroupChat == false
            }
        do {
            while true {
                try Task.checkCancellation()
                if tracksVisibility, membershipSettingsWrites > 0 {
                    _ = try await serializeGroupMutation(chatID: "\0membership-settings") {}
                }
                guard generation == requestGeneration, networkAuthorized && (ignoringPath || canFetchHistory),
                    historyCache?.accessRevoked(chatID) != true
                else { throw CancellationError() }
                let settingsRevision = membershipSettingsRevision
                let policyRevision = membershipPolicyRevisions[chatID, default: 0]
                let response = try await apiClient.listMessages(chatID: chatID, query: query)
                try Task.checkCancellation()
                guard generation == requestGeneration, historyCache?.revision == cacheRevision,
                    networkAuthorized && (ignoringPath || canFetchHistory),
                    historyCache?.accessRevoked(chatID) != true else { throw CancellationError() }
                if tracksVisibility {
                    guard membershipSettingsRevision == settingsRevision,
                        membershipSettingsWrites == 0,
                        membershipPolicyRevisions[chatID, default: 0] == policyRevision
                    else { continue }
                }
                if membershipSettingsRevision == settingsRevision, membershipSettingsWrites == 0,
                    let settings = response.chatSettings
                {
                    acceptChatSettings(settings)
                }
                if query.threadID == nil, let policy = response.membershipMessagePolicy {
                    acceptMembershipPolicy(policy, chatID: chatID)
                }
                deniedReadScopes.remove(.init(chatID: chatID, threadID: query.threadID))
                let acceptedSettingsRevision = membershipSettingsRevision
                let acceptedPolicyRevision = membershipPolicyRevisions[chatID, default: 0]
                var suppressedIndices = Set<Int>()
                for (index, message) in response.messages.enumerated() {
                    if message.isDeleted, message.chatId == chatID {
                        discardDeletedReadTargets(chatID: chatID, ids: [message.id])
                    }
                    let disposition =
                        message.isDeleted
                        ? await outgoingQueue.acceptDeletion(message)
                        : await outgoingQueue.acceptAcknowledgement(message)
                    guard generation == requestGeneration, historyCache?.revision == cacheRevision,
                        networkAuthorized && (ignoringPath || canFetchHistory),
                        historyCache?.accessRevoked(chatID) != true else { throw CancellationError() }
                    if disposition == .suppress { suppressedIndices.insert(index) }
                }
                if tracksVisibility {
                    guard membershipSettingsRevision == acceptedSettingsRevision,
                        membershipPolicyRevisions[chatID, default: 0] == acceptedPolicyRevision,
                        membershipSettingsWrites == 0
                    else { continue }
                }
                let isGroupRoot =
                    query.threadID == nil
                    && (response.membershipMessagePolicy != nil
                        || chat(id: chatID)?.kind == .group
                        || groupInfoByChatID[chatID]?.kind == .group)
                let hidesMembership =
                    isGroupRoot
                    && conversationMessages.hidesMembershipMessages(chatID: chatID)
                // A later receipt in this page may redact a reply in an earlier record.
                var visibleMessages: [MessageResponse]?
                for (index, message) in response.messages.enumerated() {
                    let suppressed = suppressedIndices.contains(index)
                    let projection = suppressed ? nil : deletedContentProjection(message)
                    if visibleMessages == nil, suppressed || projection != nil {
                        visibleMessages = Array(response.messages[..<index])
                    }
                    if !suppressed { visibleMessages?.append(projection ?? message) }
                }
                guard visibleMessages != nil || hidesMembership else { return response }
                let messages = visibleMessages ?? response.messages
                return .init(
                    messages: hidesMembership
                        ? messages.filter { $0.systemKind?.isMembership != true } : messages,
                    olderCursor: response.olderCursor, newerCursor: response.newerCursor,
                    nextCursor: response.nextCursor, prevCursor: response.prevCursor,
                    membershipMessagePolicy: response.membershipMessagePolicy,
                    chatSettings: response.chatSettings)
            }
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
        }
    }

    /// A mature, actually visible server row can be recorded with no usable
    /// path. Only a server acknowledgement updates the confirmed read cursor.
    func recordAutomaticRead(_ key: ConversationKey, target: MessageID) async throws {
        if key.threadID == target.description { return }
        try Task.checkCancellation()
        let write = AutomaticRead(
            target: target, chatVersion: pendingReadChatVersions[key.chatID, default: 0],
            version: pendingReadVersions[key, default: 0], networkVersion: readNetworkVersion)
        guard readIntentIsCurrent(key, write) else { throw CancellationError() }
        let base = confirmedReadCursors[key]
        guard base.map({ target > $0 }) ?? true else { return }
        // A freshly visible server row doesn't need cache IO or preflight GETs.
        // The existing sender serializes acknowledgements only within this scope.
        let current = generation
        let attemptedOnline = canFetchHistory && foregroundActive
        if attemptedOnline {
            do {
                try await markRead(
                    chatID: key.chatID, threadID: key.threadID, messageID: target, automatic: write)
                return
            } catch {
                if !Self.isTransientReadFailure(error)
                    && !(error is CancellationError && readNetworkVersion != write.networkVersion)
                {
                    await handleReadTargetFailure(error, key: key, intent: write, generation: current)
                    throw error
                }
                guard historyCache != nil else { throw error }
            }
        }
        // The action in flight blocks new sends, but only an accepted rewind
        // invalidates this already-observed intent. Submitting the save here
        // orders it ahead of any subsequent rewind/deletion on the cache queue.
        guard generation == current, readIntentIsCurrent(key, write, allowingPendingUnread: true)
        else { throw CancellationError() }
        if let cursor = confirmedReadCursors[key], cursor >= target { return }
        guard let save = historyCache?.accessPendingReads({
            try await $0.recordPendingRead(key, base: base, target: target)
        }) else { throw CancellationError() }
        let recording = try await save.value
        guard generation == current, readIntentIsCurrent(key, write)
        else { throw CancellationError() }
        // A path transition may have started its sweep before this save landed.
        // On the same healthy path, leave transient failures for the next wake.
        if recording != .unchanged, canFetchHistory,
            !attemptedOnline || write.networkVersion != readNetworkVersion
        {
            pendingReadWakes.insert(key)
            startPendingReadWorker()
        }
    }

    @discardableResult
    func replayPendingReads() -> Task<Void, Never>? {
        guard canFetchHistory, foregroundActive, historyCache?.isAvailable == true else { return nil }
        if pendingReadSweepVersion != readNetworkVersion { pendingReadSweepRequested = true }
        startPendingReadWorker()
        return pendingReadTask
    }

    private func startPendingReadWorker() {
        guard pendingReadTask == nil, canFetchHistory, foregroundActive,
            let historyCache, historyCache.isAvailable
        else { return }
        let current = generation
        pendingReadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == current {
                    pendingReadTask = nil
                    pendingReadSweepVersion = nil
                }
            }
            while generation == current, canFetchHistory, foregroundActive, !Task.isCancelled {
                if pendingReadSweepRequested {
                    pendingReadSweepRequested = false
                    pendingReadSweepVersion = readNetworkVersion
                    let scan = historyCache.accessPendingReads { try await $0.pendingReads() }
                    if let rows = try? await scan?.value, generation == current {
                        pendingReadWakes.formUnion(rows.lazy.map(\.key))
                    }
                }
                guard generation == current, canFetchHistory, foregroundActive,
                    let key = pendingReadWakes.popFirst()
                else { return }
                await replayPendingRead(key, cache: historyCache, generation: current)
            }
        }
    }

    private func replayPendingRead(
        _ key: ConversationKey, cache: AccountHistoryCache, generation current: Int
    ) async {
        let version = pendingReadVersions[key, default: 0]
        let chatVersion = pendingReadChatVersions[key.chatID, default: 0]
        let networkVersion = readNetworkVersion
        let lookup = cache.accessPendingReads { try await $0.pendingRead(key) }
        guard let pending = try? await lookup?.value else { return }
        guard generation == current else { return }
        if conversationMessages.deletedMessageIDs(chatID: key.chatID).contains(pending.target) {
            discardReadTarget(key, target: pending.target)
            return
        }
        let intent = AutomaticRead(
            target: pending.target, chatVersion: chatVersion, version: version, networkVersion: networkVersion)
        guard canSendReadIntent(key, intent, generation: current) else { return }
        let fresh: ReadStateResponse
        do {
            fresh = try await fetchConversationReadState(
                chatID: key.chatID, threadID: key.threadID, ignoringWatch: true, requireFresh: true)
        } catch {
            guard canSendReadIntent(key, intent, generation: current) else { return }
            switch Self.readHTTPStatus(error) {
            case 403: removeGroupFromLists(chatID: key.chatID)
            case 400, 404: discardReadTarget(key, target: pending.target)
            default: break
            }
            return
        }
        guard canSendReadIntent(key, intent, generation: current) else { return }
        let cursor = fresh.lastReadMessageId
        if let cursor, cursor >= pending.target {
            clearPendingRead(key, through: cursor)
            return
        }
        if let base = pending.base, cursor.map({ $0 < base }) ?? true {
            discardReadTarget(key, target: pending.target)
            return
        }
        // The read endpoints accept a deleted identity. Revalidate the saved
        // target itself rather than advancing to a different message.
        do {
            let message = try await performGroupRequest(generation: current) {
                try await apiClient.getMessage(chatID: key.chatID, messageID: pending.target)
            }
            guard message.chatId == key.chatID, message.id == pending.target,
                message.replyRootId == key.threadID, !message.isDeleted
            else { throw InvalidAutomaticReadTarget() }
        } catch {
            await handleReadTargetFailure(error, key: key, intent: intent, generation: current)
            return
        }
        let latest = cache.accessPendingReads { try await $0.pendingRead(key) }
        guard let value = try? await latest?.value, value == pending,
            canSendReadIntent(key, intent, generation: current)
        else { return }
        do {
            try await markRead(
                chatID: key.chatID, threadID: key.threadID, messageID: pending.target,
                automatic: intent)
        } catch {
            await handleReadTargetFailure(error, key: key, intent: intent, generation: current)
        }
    }

    private struct InvalidAutomaticReadTarget: Error {}

    private static func readHTTPStatus(_ error: Error) -> Int? {
        switch error {
        case APIError.http(let status, _), APIError.invalidResponse(let status): status
        default: nil
        }
    }

    private static func isTransientReadFailure(_ error: Error) -> Bool {
        switch error {
        case APIError.transport, APIError.unavailable, APIError.retryableHTTP:
            return true
        default:
            guard let status = readHTTPStatus(error) else { return false }
            return status == 408 || status == 429 || (500...599).contains(status)
        }
    }

    private func handleReadTargetFailure(
        _ error: Error, key: ConversationKey, intent: AutomaticRead, generation current: Int
    ) async {
        guard generation == current, networkAuthorized, readIntentIsCurrent(key, intent) else { return }
        let status = Self.readHTTPStatus(error)
        if status == 403 {
            removeGroupFromLists(chatID: key.chatID)
        } else if status == 400 || status == 404 || error is InvalidAutomaticReadTarget {
            discardReadTarget(key, target: intent.target)
            if canFetchHistory {
                _ = try? await fetchConversationReadState(
                    chatID: key.chatID, threadID: key.threadID, ignoringWatch: true, requireFresh: true)
            }
        }
    }

    private func readIntentIsCurrent(
        _ key: ConversationKey, _ intent: AutomaticRead, allowingPendingUnread: Bool = false
    ) -> Bool {
        pendingReadVersions[key, default: 0] == intent.version
            && pendingReadChatVersions[key.chatID, default: 0] == intent.chatVersion
            && (allowingPendingUnread || pendingListActions[key] != .markUnread)
            && historyCache?.accessRevoked(key.chatID) != true
            && !deniedReadScopes.contains(key)
            && !conversationMessages.deletedMessageIDs(chatID: key.chatID).contains(intent.target)
    }

    private func canSendReadIntent(
        _ key: ConversationKey, _ intent: AutomaticRead, generation current: Int
    ) -> Bool {
        generation == current && canFetchHistory && foregroundActive && !Task.isCancelled
            && readNetworkVersion == intent.networkVersion && readIntentIsCurrent(key, intent)
    }

    private func clearPendingRead(_ key: ConversationKey, through target: MessageID? = nil) {
        _ = historyCache?.accessPendingReads { try await $0.clearPendingRead(key, through: target) }
    }

    private func discardReadTarget(_ key: ConversationKey, target: MessageID) {
        _ = historyCache?.accessPendingReads { try await $0.clearPendingReadTarget(key, target: target) }
    }

    private func discardDeletedReadTargets(chatID: String, ids: Set<MessageID>) {
        let newIDs = ids.subtracting(conversationMessages.deletedMessageIDs(chatID: chatID))
        guard !newIDs.isEmpty else { return }
        conversationMessages.redactPendingReplies(newIDs, chatID: chatID)
        _ = historyCache?.accessPendingReads { try await $0.clearPendingReadTargets(chatID: chatID, ids: newIDs) }
    }

    private func invalidatePendingRead(_ key: ConversationKey) {
        pendingReadVersions[key, default: 0] += 1
        pendingReadWakes.remove(key)
        clearPendingRead(key)
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
        try await markRead(chatID: chatID, threadID: threadID, messageID: messageID, automatic: nil)
    }

    private func markRead(
        chatID: String, threadID: String?, messageID: MessageID, automatic: AutomaticRead?
    ) async throws {
        guard networkAuthorized else { throw CancellationError() }
        try Task.checkCancellation()
        if threadID == messageID.description { return }
        let requestGeneration = generation
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        if let automatic, !canSendReadIntent(key, automatic, generation: requestGeneration) {
            throw CancellationError()
        }
        // Share an in-flight acknowledgement, then recheck authoritative progress.
        // A failure remains a failure, never a speculative read watermark.
        while let acknowledgement = readAcknowledgements[key] {
            if let cursor = automatic == nil ? conversationReadStates[key]?.lastReadMessageId : confirmedReadCursors[key],
                cursor >= messageID
            {
                if let confirmed = confirmedReadCursors[key] { clearPendingRead(key, through: confirmed) }
                return
            }
            do {
                try await acknowledgement.task.value
            } catch {
                guard generation == requestGeneration else { throw CancellationError() }
                // A newer unread intent supersedes this operation, not a new
                // caller waiting to reread from that reset baseline.
                if acknowledgement.resetVersion == readResetVersions[key, default: 0] {
                    throw error
                }
            }
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
        }
        if let automatic, !canSendReadIntent(key, automatic, generation: requestGeneration) {
            throw CancellationError()
        }
        if let cursor = automatic == nil ? conversationReadStates[key]?.lastReadMessageId : confirmedReadCursors[key],
            cursor >= messageID
        {
            if let confirmed = confirmedReadCursors[key] { clearPendingRead(key, through: confirmed) }
            return
        }
        advanceReadStateVersion(for: key)
        rowRevisions[key, default: 0] += 1
        let token = readStateVersion
        let resetVersion = readResetVersions[key, default: 0]
        let task = Task {
            try await self.performReadAcknowledgement(
                key: key, messageID: messageID, token: token, resetVersion: resetVersion,
                generation: requestGeneration, automatic: automatic)
        }
        readAcknowledgements[key] = .init(
            token: token, requestedCursor: messageID, resetVersion: resetVersion, task: task)
        try await task.value
    }

    private func performReadAcknowledgement(
        key: ConversationKey, messageID: MessageID, token: Int, resetVersion: Int,
        generation requestGeneration: Int, automatic: AutomaticRead?
    ) async throws {
        defer {
            if generation == requestGeneration, readAcknowledgements[key]?.token == token {
                readAcknowledgements.removeValue(forKey: key)
            }
        }
        do {
            try Task.checkCancellation()
            guard networkAuthorized, generation == requestGeneration,
                readResetVersions[key, default: 0] == resetVersion,
                automatic.map({ canSendReadIntent(key, $0, generation: requestGeneration) }) ?? true
            else { throw CancellationError() }
            let settingsRevision = membershipSettingsRevision
            let policyRevision = membershipPolicyRevisions[key.chatID, default: 0]
            let response: ReadStateResponse
            if let threadID = key.threadID {
                response = try await apiClient.markThreadRead(
                    chatID: key.chatID, threadID: threadID, messageID: messageID)
            } else {
                response = try await apiClient.markChatRead(
                    chatID: key.chatID, messageID: messageID)
            }
            guard networkAuthorized, generation == requestGeneration,
                readResetVersions[key, default: 0] == resetVersion,
                automatic.map({ readIntentIsCurrent(key, $0) }) ?? true
            else { throw CancellationError() }
            if let cursor = response.lastReadMessageId { clearPendingRead(key, through: cursor) }
            if key.threadID == nil,
                membershipSettingsRevision != settingsRevision
                    || membershipPolicyRevisions[key.chatID, default: 0] != policyRevision
            {
                if let cursor = response.lastReadMessageId { onNotificationRead?(key, cursor) }
                fallbackConversationStates(key)
                return
            }
            let watchedThrough = readAcknowledgements[key]?.watchedThrough
            if let cursor = response.lastReadMessageId,
                let watchedThrough, watchedThrough >= cursor
            {
                // The ordered stream already acknowledged this write. Its later
                // counts (or a subsequent mark-unread) outrank this HTTP snapshot.
                onNotificationRead?(key, cursor)
                return
            }
            if let cursor = conversationReadStates[key]?.lastReadMessageId,
                let returnedCursor = response.lastReadMessageId, cursor > returnedCursor
            {
                onNotificationRead?(key, cursor)
                return
            }
            applyReadState(response, chatID: key.chatID, threadID: key.threadID)
            if let cursor = response.lastReadMessageId {
                readFences[key] = .init(
                    cursor: cursor, version: readStateVersion, watchRequestID: statesRequestID)
                onNotificationRead?(key, cursor)
                if readAcknowledgements[key]?.sawWatchedState == true {
                    reconcileReadFence(key)
                }
            }
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
        }
    }

    private func advanceReadStateVersion(for key: ConversationKey) {
        readStateVersion += 1
        readStateVersions[key] = readStateVersion
    }

    /// Requests started before a read update retain that scope's current fields,
    /// while the rest of a list snapshot remains usable. A fresh authoritative
    /// request can end the temporary WS fence, including a remote mark-unread.
    private func resolveReadSnapshot(
        _ response: ReadStateResponse, key: ConversationKey, version: Int
    ) -> ReadStateResponse {
        if readStateVersions[key, default: 0] > version,
            let cached = conversationReadStates[key]
        {
            return cached
        }
        if let fence = readFences[key], version >= fence.version {
            readFences.removeValue(forKey: key)
        }
        cacheReadState(response, key: key)
        return response
    }

    private func cacheReadState(
        _ response: ReadStateResponse, key: ConversationKey, resetWatermark: Bool = false,
        confirmsCursor: Bool = true
    ) {
        if confirmsCursor {
            let confirmed = confirmedReadCursors[key]
            let rewound = confirmed.map { previous in
                response.lastReadMessageId.map { $0 < previous } ?? true
            } ?? false
            confirmedReadCursors[key] = response.lastReadMessageId
            if resetWatermark || rewound { invalidatePendingRead(key) }
        }
        guard response != conversationReadStates[key] || resetWatermark else { return }
        let previousCursor = conversationReadStates[key]?.lastReadMessageId
        let rewound =
            previousCursor.map { previous in
                response.lastReadMessageId.map { $0 < previous } ?? true
            } ?? false
        conversationReadStates[key] = response
        advanceReadStateVersion(for: key)
        if resetWatermark || rewound {
            readFences.removeValue(forKey: key)
            if resetWatermark || readAcknowledgements[key] == nil
                || readAcknowledgements[key].map({
                    guard let watched = $0.watchedThrough else { return false }
                    return watched >= $0.requestedCursor
                }) == true
            {
                readResetVersions[key, default: 0] += 1
            }
            for model in visibleTimelines()
            where model.chatID == key.chatID && model.threadID == key.threadID {
                model.resetReadWatermark(to: response.lastReadMessageId)
            }
        }
    }

    private func applyReadState(
        _ response: ReadStateResponse, chatID: String, threadID: String?,
        resetWatermark: Bool = false, confirmsCursor: Bool = true
    ) {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        cacheReadState(response, key: key, resetWatermark: resetWatermark, confirmsCursor: confirmsCursor)
        rowRevisions[key, default: 0] += 1
        if let threadID, let thread = thread(chatID: chatID, threadID: threadID) {
            install(thread.withReadState(response))
        } else if threadID == nil, let chat = chat(id: chatID) {
            install(chat.withReadState(response))
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
        readFenceReconciliations.removeAll()
        for task in rowTasks.values { task.cancel() }
        rowTasks.removeAll()
        dirtyRows.removeAll()
        refreshGeneration += 1
        for refresh in refreshTasks.values { refresh.task.cancel() }
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
        fullSnapshotRecoveries.removeAll()
        for task in recoveryTasks.values { task.cancel() }
        recoveryTasks.removeAll()
    }

    func reset() {
        displayPreferences.activate(uid: nil)
        generation += 1
        pendingReadTask?.cancel()
        pendingReadTask = nil
        pendingReadSweepRequested = false
        pendingReadSweepVersion = nil
        pendingReadWakes.removeAll()
        deniedReadScopes.removeAll()
        confirmedReadCursors.removeAll()
        pendingReadVersions.removeAll()
        pendingReadChatVersions.removeAll()
        sessionRevision += 1
        clearCachedListPresentation()
        messageStorageFull = false
        confirmedThreadRoots.removeAll()
        groupInfoByChatID.removeAll()
        memberSpeakingModesByChatID.removeAll()
        groupInfoRevisions.removeAll()
        groupInfoInvalidations.removeAll()
        groupInfoReadSequences.removeAll()
        groupSpeakingRevisions.removeAll()
        memberSpeakingRevisions.removeAll()
        membershipPolicies.removeAll()
        membershipPolicyRevisions.removeAll()
        membershipSettingsRevision += 1
        membershipSettingsWrites = 0
        membershipChatSettings = nil
        messageUpdateError = nil
        notificationRevision += 1
        savedSendDecisions.removeAll()
        sendPermissionVersions.removeAll()
        sendPermissionPeers.removeAll()
        peerPermissionVersion &+= 1
        dispatchPermissionChecks.removeAll()
        notificationVersions.removeAll()
        notificationSnapshots.removeAll()
        defaultsRevision += 1
        notificationDefaultsSaving = false
        defaultsLoadTask?.cancel()
        defaultsLoadTask = nil
        defaultsLoadRequested = false
        notificationExpiryTask?.cancel()
        notificationExpiryTask = nil
        notificationExpiry = nil
        presenceConsumers.removeAll()
        presenceScope = PresenceScope()
        presenceScopeChanges.send(())
        clearPresence()
        clearConversationWatches()
        conversationConsumers.removeAll()
        conversationStateScope = []
        conversationStateScopeChanges.send(())
        conversationReadStates.removeAll()
        localStateWrites.removeAll()
        for acknowledgement in readAcknowledgements.values { acknowledgement.task.cancel() }
        readAcknowledgements.removeAll()
        readFences.removeAll()
        readStateVersions.removeAll()
        readResetVersions.removeAll()
        membershipStates.removeAll()
        membershipRevision += 1
        rowRevisions.removeAll()
        cancelQueuedGroupMutations()
        pendingListActions.removeAll()
        deletingMessageIDs.removeAll()
        listActionError = nil
        drafts.reset()
        outgoingRevisions.removeAll()
        pendingListPreviews.removeAll()
        listReadReceipts.reset()
        cancelRealtimeRecovery()
        reactions.reset()
        pins.reset()
        stickers.reset()
        savedMessages.reset()
        VoicePlaybackSession.shared.stop()
        VoicePlaybackController.stopAll()
        conversationMessages.reset()
        setRealtimeStatus(.idle)
        state = ChatState()
    }
}

extension ChatListItem {
    fileprivate var readState: ReadStateResponse {
        .init(
            lastReadMessageId: lastReadMessageId, unreadCount: unreadCount,
            unreadMentions: unreadMentions, unreadReactions: unreadReactions)
    }

    fileprivate func withReadState(_ response: ReadStateResponse) -> ChatListItem {
        guard response != readState else { return self }
        return ChatListItem(
            id: id, name: name, avatar: avatar, lastMessageAt: lastMessageAt,
            unreadCount: response.unreadCount, unreadMentions: response.unreadMentions,
            unreadReactions: response.unreadReactions,
            lastReadMessageId: response.lastReadMessageId,
            peerLastReadMessageId: peerLastReadMessageId,
            lastMessage: lastMessage, mutedUntil: mutedUntil, muteOverride: muteOverride,
            isMuted: isMuted, archived: archived, kind: kind, peer: peer,
            membershipMessagePolicy: membershipMessagePolicy)
    }

    fileprivate func withPreview(
        _ preview: MessagePreview?, preserveActivity: Bool = false
    ) -> ChatListItem {
        ChatListItem(
            id: id, name: name, avatar: avatar,
            lastMessageAt: preserveActivity ? lastMessageAt : preview?.createdAt,
            unreadCount: unreadCount, unreadMentions: unreadMentions,
            unreadReactions: unreadReactions, lastReadMessageId: lastReadMessageId,
            peerLastReadMessageId: peerLastReadMessageId,
            lastMessage: preview, mutedUntil: mutedUntil, muteOverride: muteOverride,
            isMuted: isMuted, archived: archived,
            kind: kind, peer: peer, membershipMessagePolicy: membershipMessagePolicy)
    }
}

extension ThreadListItem {
    fileprivate var readState: ReadStateResponse {
        .init(
            lastReadMessageId: lastReadMessageId, unreadCount: unreadCount,
            unreadMentions: unreadMentions, unreadReactions: unreadReactions)
    }

    fileprivate func withReadState(_ response: ReadStateResponse) -> ThreadListItem {
        guard response != readState else { return self }
        return ThreadListItem(
            chatId: chatId, chatName: chatName, chatAvatar: chatAvatar,
            threadRootMessage: threadRootMessage, peer: peer,
            lastReply: lastReply, replyCount: replyCount, lastReplyAt: lastReplyAt,
            unreadCount: response.unreadCount, unreadMentions: response.unreadMentions,
            unreadReactions: response.unreadReactions,
            lastReadMessageId: response.lastReadMessageId,
            peerLastReadMessageId: peerLastReadMessageId, chatKind: chatKind,
            subscribedAt: subscribedAt, archived: archived)
    }

    fileprivate func withActivity(
        root: MessagePreview? = nil, lastReply: MessagePreview? = nil,
        replyCount: Int64? = nil, lastReplyAt: Date? = nil
    ) -> ThreadListItem {
        ThreadListItem(
            chatId: chatId, chatName: chatName, chatAvatar: chatAvatar,
            threadRootMessage: root ?? threadRootMessage, peer: peer,
            lastReply: lastReply ?? self.lastReply, replyCount: replyCount ?? self.replyCount,
            lastReplyAt: lastReplyAt ?? self.lastReplyAt, unreadCount: unreadCount,
            unreadMentions: unreadMentions, unreadReactions: unreadReactions,
            lastReadMessageId: lastReadMessageId, peerLastReadMessageId: peerLastReadMessageId,
            chatKind: chatKind,
            subscribedAt: subscribedAt, archived: archived)
    }
}
