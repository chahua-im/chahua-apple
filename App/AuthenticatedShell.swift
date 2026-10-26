import ChahuaAPI
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Authenticated navigation boundary.
///
/// This view owns signed-in navigation state; feature stores own server data.
struct AuthenticatedShell: View {
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var notifications: PushNotificationCoordinator
    let notificationSceneID: UUID
    let me: MeResponse
    let isSigningOut: Bool
    let onSignOut: () -> Void
    var pendingURL: Binding<URL?> = .constant(nil)

    @State private var selectedScope: ConversationListScope = .messages
    @State private var archivedScope: ConversationListScope = .messages
    @AppStorage(ConversationListPreferences.showThreadsInMessagesStorageKey)
    private var showThreadsInMessages = ConversationListPreferences.defaultShowThreadsInMessages
    @AppStorage(ConversationListPreferences.unreadBadgeColorStorageKey)
    private var unreadBadgeColorRawValue = ConversationListPreferences.defaultUnreadBadgeColor
        .rawValue
    @State private var listPath: [NavigationRoute] = []
    @State private var selectedConversationID: ConversationKey?
    @State private var showsSettings = false
    @State private var isVisible = false
    @State private var messageNavigation: MessageNavigation?
    @State private var messageSearch: MessageSearchSession?
    @State private var groupPath: [GroupRoute] = []
    @State private var forwardThreadAction: ForwardThreadAction?
    @State private var threadInfoAction: ThreadInfoAction?
    @State private var feature: FeatureDestination?
    @State private var profilePath: [Int32] = []
    @State private var navigationError: String?
    @State private var isListRefreshing = false
    @StateObject private var listPresentation = ConversationListPresentation()

    private enum FeatureDestination: Hashable, Identifiable {
        case addFriend, createGroup
        case joinGroup(String)
        case profile(Int32)
        var id: Self { self }

        var showsDoneButton: Bool {
            switch self {
            case .profile: false
            default: true
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    private enum NavigationRoute: Hashable {
        case archive
        case conversation(ConversationKey)
        case group(GroupRoute)
        case friendRequests(FriendRequestRoute)
    }

    private enum FriendRequestRoute: Hashable {
        case list
        case profile(Int32)
    }

    private enum GroupRoute: Hashable {
        case info(ChatListItem)
        case search(ChatListItem)
        case source(ChatListItem, MessageResponse)
        case thread(ChatListItem, MessageResponse)
    }

    private var isBrowsingArchived: Bool { listPath.first == .archive }

    private var isBrowsingFriendRequests: Bool {
        listPath.contains {
            if case .friendRequests = $0 { return true }
            return false
        }
    }

    // macOS archive navigation retains its existing immediate list switch.
    // Only request/profile destinations push above that list, never into chat detail.
    private var friendRequestPath: Binding<[FriendRequestRoute]> {
        Binding(
            get: {
                listPath.compactMap {
                    guard case .friendRequests(let route) = $0 else { return nil }
                    return route
                }
            },
            set: { routes in
                listPath =
                    (isBrowsingArchived ? [.archive] : [])
                    + routes.map(NavigationRoute.friendRequests)
            })
    }

    private var unreadBadgeColor: ConversationUnreadBadgeColor {
        ConversationUnreadBadgeColor(rawValue: unreadBadgeColorRawValue)
            ?? ConversationListPreferences.defaultUnreadBadgeColor
    }

    private func scopeBinding(archived: Bool) -> Binding<ConversationListScope> {
        Binding(
            get: {
                archived ? archivedScope : selectedScope
            },
            set: { scope in
                if archived {
                    archivedScope = scope
                } else {
                    selectedScope = scope
                }
            })
    }

    /// Opens a chat timeline positioned at one message.
    ///
    /// Notification payloads are unauthorized hints whose chat is resolved by
    /// `ChatStore.chatForNotification`; search results already carry their chat.
    private struct MessageNavigation {
        let id = UUID()
        let conversation: ConversationKey
        let messageID: MessageID
        let userID: Int32
        let notificationRoute: PushNotificationRoute?
        var requestID = UUID()
        var chat: ChatListItem?
        var failed = false

        init(notification route: PushNotificationRoute, userID: Int32) {
            conversation = route.conversation
            messageID = route.messageID
            self.userID = userID
            notificationRoute = route
        }

        /// Thread replies open through `ThreadNavigation` so Back returns to the chat.
        init(searchResult message: MessageResponse, in chat: ChatListItem, userID: Int32) {
            conversation = .init(chatID: chat.id, threadID: nil)
            messageID = message.id
            self.userID = userID
            notificationRoute = nil
            self.chat = chat
        }
    }

    private struct ThreadNavigation {
        /// View identity: each navigation rebuilds the thread timeline at its position.
        let id = UUID()
        let chat: ChatListItem
        let rootID: String
        let title: String
        var initialMessageID: MessageID?
        /// Timeline navigation already has the authoritative root; reuse its author in the header.
        var root: MessageResponse?
        var key: ConversationKey { .init(chatID: chat.id, threadID: rootID) }
    }

    /// Search state retained for the selected chat while its sheet is dismissed.
    private struct MessageSearchSession {
        let chat: ChatListItem
        let model: MessageSearchModel
    }

    @State private var openedThread: ThreadNavigation?
    @State private var threadPath: [ConversationKey] = []
    @State private var threadSubscription: ThreadSubscriptionModel?

    var body: some View {
        GeometryReader { geometry in
            #if os(macOS)
                adaptiveLayout
            #else
                if geometry.size.width >= ChatSplitMetrics.splitThreshold {
                    adaptiveLayout
                } else {
                    listNavigation(includesDetail: true)
                }
            #endif
        }
        .onPreferenceChange(ForwardThreadActionKey.self) { forwardThreadAction = $0 }
        .onPreferenceChange(ThreadInfoActionKey.self) { threadInfoAction = $0 }
        .environment(\.openUserProfile, openProfile)
        .environment(\.openGroupInvite) { feature = .joinGroup($0) }
        .environment(\.openForwardDestination, openForwardDestination)
        .sheet(item: $feature, onDismiss: { profilePath.removeAll() }) { destination in
            NavigationStack(path: $profilePath) {
                featureDestination(destination)
                    .navigationDestination(for: Int32.self) { uid in
                        UserProfileView(
                            uid: uid, currentUserID: me.uid, store: chatStore,
                            onOpenChat: openChat)
                    }
                    .toolbar {
                        if destination.showsDoneButton {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { feature = nil }
                            }
                        }
                    }
            }
            .environment(\.openUserProfile, openProfile)
            .environment(\.openGroupInvite) { feature = .joinGroup($0) }
            .environment(\.openForwardDestination, openForwardDestination)
            .frame(minWidth: 320, minHeight: 420)
        }
        .task(id: pendingURL.wrappedValue) {
            guard let url = pendingURL.wrappedValue else { return }
            await openIncomingURL(url)
            if pendingURL.wrappedValue == url { pendingURL.wrappedValue = nil }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VoicePlaybackBar { message in
                Task { await openVoiceSource(message) }
            }
        }
        .alert(
            "Unable to open",
            isPresented: Binding(
                get: { navigationError != nil },
                set: { if !$0 { navigationError = nil } })
        ) {
            Button("OK", role: .cancel) { navigationError = nil }
        } message: {
            Text(navigationError ?? "")
        }
        .onChange(of: chatStore.state) { _, state in
            guard let selectedConversationID, messageNavigation == nil else { return }
            let loaded =
                selectedConversationID.threadID == nil
                ? (isBrowsingArchived ? state.archivedChatListLoadPhase : state.chatListLoadPhase)
                    == .loaded
                : (isBrowsingArchived
                    ? state.archivedThreadListLoadPhase : state.threadListLoadPhase) == .loaded
            if loaded && selectedConversation == nil { selectConversation(nil) }
        }
        .task(id: notifications.pendingNavigation?.id) { claimNotification() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { claimNotification() }
        }
        .task(id: messageNavigation?.requestID) { await resolveNotification() }
        .onChange(of: me.uid) { _, _ in
            selectConversation(nil)
            showsSettings = false
            listPath.removeAll()
            feature = nil
            profilePath.removeAll()
            listPresentation.reset()
            isListRefreshing = false
            VoicePlaybackSession.shared.stop()
            VoicePlaybackController.stopAll()
            archivedScope = .messages
        }
        .onChange(of: isSigningOut) { _, signingOut in
            if signingOut {
                selectConversation(nil)
                listPath.removeAll()
                feature = nil
                listPresentation.reset()
                isListRefreshing = false
                VoicePlaybackSession.shared.stop()
                VoicePlaybackController.stopAll()
            }
        }
        .onAppear {
            isVisible = true
            reportVisibleConversation()
        }
        .onChange(of: visibleConversation) { _, _ in reportVisibleConversation() }
        .onChange(of: headerThreadKey, initial: true) { _, key in
            guard threadSubscription?.key != key else { return }
            threadSubscription = key.flatMap { key in
                key.threadID.map {
                    ThreadSubscriptionModel(chatID: key.chatID, threadID: $0, store: chatStore)
                }
            }
        }
        .onDisappear {
            isVisible = false
            notifications.setVisibleConversation(sceneID: notificationSceneID, conversation: nil)
        }
        .sheet(
            isPresented: Binding(
                get: { showsSettings && !usesAccountHero },
                set: { showsSettings = $0 }
            )
        ) {
            #if os(macOS)
                settings
                    .frame(minWidth: 760, idealWidth: 880, minHeight: 540, idealHeight: 640)
            #else
                settings
                    .frame(minWidth: 320, idealWidth: 560, minHeight: 520, idealHeight: 640)
            #endif
        }
        #if os(iOS)
            .modifier(
                AccountProfilePresentation(
                    isPresented: showsSettings && usesAccountHero,
                    avatarURL: me.avatarUrl.flatMap(URL.init(string:)),
                    displayName: me.username
                ) {
                    settings
                })
        #endif
    }

    private var adaptiveLayout: some View {
        ChatSplitLayout(hasSelection: selectedConversationID != nil) { _ in
            #if os(iOS)
                // Archive pushes within the sidebar without changing the split detail selection.
                listNavigation(includesDetail: false)
            #else
                NavigationStack(path: friendRequestPath) {
                    chatList(archived: isBrowsingArchived)
                        .navigationDestination(for: FriendRequestRoute.self) { route in
                            friendRequestDestination(route)
                        }
                }
            #endif
        } detail: { isSplit in
            NavigationStack(path: $groupPath) {
                Group {
                    if let key = threadPath.last {
                        threadDestination(key)
                    } else {
                        detailContent
                    }
                }
                .modifier(
                    ChatHeaderOverlay(isVisible: selectedConversationID != nil) {
                        ChatFloatingHeader(
                            title: threadPath.isEmpty
                                ? selectedTitle
                                : openedThread?.title ?? AppLanguage.localized("Thread"),
                            subtitle: threadPath.isEmpty ? headerSubtitle : nil,
                            isMuted: threadPath.isEmpty && headerChatIsMuted,
                            onBack: !threadPath.isEmpty
                                ? popThread : isSplit ? nil : { selectConversation(nil) },
                            onClose: isSplit && threadPath.isEmpty
                                ? { selectConversation(nil) } : nil,
                            onOpenInfo: infoAction,
                            onSearch: searchAction,
                            onForward: forwardThreadAction?.conversation == headerThreadKey
                                ? forwardThreadAction?.perform : nil,
                            trailingIsControl: headerThreadKey != nil,
                            backBadgeCount: backBadgeCount,
                            leadingAvatar: headerLeading(for: headerThreadKey)
                        ) {
                            headerTrailing(for: headerThreadKey)
                        }
                        .presenceScope(
                            ChatPresenceDisplay.scope(
                                for: threadPath.isEmpty ? selectedInfoChat : nil),
                            store: chatStore
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                )
                #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                #endif
                .navigationDestination(for: GroupRoute.self) { route in
                    groupDestination(route)
                }
            }
        }
    }

    #if os(iOS)
        private func listNavigation(includesDetail: Bool) -> some View {
            NavigationStack(path: includesDetail ? phonePath : $listPath) {
                // The active root stays active underneath the pushed archive list.
                chatList(archived: false)
                    .navigationDestination(for: NavigationRoute.self) { route in
                        switch route {
                        case .archive:
                            chatList(archived: true)
                                .background(ConversationSwipeBack(allowsContentSwipeBack: false))
                        case .friendRequests(let route):
                            friendRequestDestination(route)
                        case .conversation(let key):
                            Group {
                                if openedThread?.key == key {
                                    threadDestination(key)
                                } else {
                                    detailContent
                                }
                            }
                            // iPhone conversations draw the same header as the split
                            // layout instead of the system bar: the system back button
                            // cannot show the unread pill (as Messages and Telegram do).
                            // UIKit still owns push/pop; `ConversationSwipeBack` keeps
                            // swipe-back working with the bar hidden.
                            .modifier(
                                ChatHeaderOverlay {
                                    ChatFloatingHeader(
                                        title: openedThread?.key == key
                                            ? openedThread?.title
                                                ?? AppLanguage.localized("Thread")
                                            : selectedTitle,
                                        subtitle: key.threadID == nil ? headerSubtitle : nil,
                                        isMuted: key.threadID == nil && headerChatIsMuted,
                                        onBack: { popPhoneConversation(key) },
                                        onOpenInfo: infoAction,
                                        onSearch: searchAction,
                                        onForward: forwardThreadAction?.conversation == key
                                            ? forwardThreadAction?.perform : nil,
                                        trailingIsControl: key.threadID != nil,
                                        backBadgeCount: backBadgeCount,
                                        leadingAvatar: headerLeading(for: key)
                                    ) {
                                        headerTrailing(for: key)
                                    }
                                    .presenceScope(
                                        ChatPresenceDisplay.scope(
                                            for: key.threadID == nil ? selectedInfoChat : nil),
                                        store: chatStore
                                    )
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                }
                            )
                            .toolbar(.hidden, for: .navigationBar)
                            .background(ConversationSwipeBack())
                        case .group(let route):
                            groupDestination(route)
                        }
                    }
            }
        }

        /// Back from a phone conversation: a thread pushed over its chat returns to
        /// the chat; anything else returns to the list.
        private func popPhoneConversation(_ key: ConversationKey) {
            if openedThread?.key == key {
                popThread()
            } else {
                selectConversation(nil)
            }
        }

        private var phonePath: Binding<[NavigationRoute]> {
            Binding(
                get: {
                    var path = listPath
                    if let selectedConversationID, !isBrowsingFriendRequests {
                        path.append(.conversation(selectedConversationID))
                        path.append(contentsOf: threadPath.map(NavigationRoute.conversation))
                        path.append(contentsOf: groupPath.map(NavigationRoute.group))
                    }
                    return path
                },
                set: { path in
                    listPath = Array(
                        path.prefix {
                            switch $0 {
                            case .archive, .friendRequests: true
                            case .conversation, .group: false
                            }
                        })
                    if isBrowsingFriendRequests { return }
                    let conversations = path.dropFirst(listPath.count).compactMap {
                        route -> ConversationKey? in
                        guard case .conversation(let key) = route else { return nil }
                        return key
                    }
                    if conversations.first != selectedConversationID {
                        selectConversation(conversations.first)
                    }
                    threadPath = Array(conversations.dropFirst())
                    groupPath = path.compactMap { route in
                        guard case .group(let group) = route else { return nil }
                        return group
                    }
                }
            )
        }
    #endif

    private func chatList(archived: Bool) -> some View {
        let scope = scopeBinding(archived: archived)
        let badges = ConversationTabBadges(
            summaries: chatStore.state.conversationUnreadSummaries,
            archived: archived, showThreadsInMessages: showThreadsInMessages)
        let list = ChatListView(
            store: chatStore,
            drafts: chatStore.drafts,
            currentUserID: me.uid,
            scope: scope.wrappedValue,
            archivedMode: archived,
            showThreadsInMessages: showThreadsInMessages,
            onOpenArchived: openArchived,
            onOpenFriendRequestHistory: openFriendRequests,
            badgeColor: unreadBadgeColor,
            presentation: listPresentation,
            selectedConversationID: selectedConversationID,
            onSelectConversation: { selectConversation($0.id) }
        )
        return VStack(spacing: 0) {
            ConversationListHeader(
                selection: scope, badges: badges,
                badgeColor: unreadBadgeColor, onBack: archived ? { closeArchived() } : nil,
                isUpdating: isListRefreshing,
                account: { accountButton },
                actions: { creationButton })
            list
        }
        .onPreferenceChange(ConversationListRefreshingKey.self) { isListRefreshing = $0 }
        #if os(iOS)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private func openArchived() {
        guard listPath.isEmpty else { return }
        archivedScope = selectedScope
        listPath.append(.archive)
    }

    private func closeArchived() {
        listPath.removeAll()
    }

    private func openFriendRequests() {
        guard !isBrowsingFriendRequests else { return }
        listPath.append(.friendRequests(.list))
    }

    @ViewBuilder
    private func friendRequestDestination(_ route: FriendRequestRoute) -> some View {
        Group {
            switch route {
            case .list:
                FriendRequestsView(
                    currentUserID: me.uid, store: chatStore,
                    onOpenProfile: { listPath.append(.friendRequests(.profile($0))) })
            case .profile(let uid):
                UserProfileView(
                    uid: uid, currentUserID: me.uid, store: chatStore,
                    onOpenChat: openChat)
            }
        }
        .environment(\.chatHeaderInset, 0)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
        #endif
    }

    @ViewBuilder private var detailContent: some View {
        if let navigation = messageNavigation,
            navigation.conversation == selectedConversationID
        {
            if let chat = navigation.chat {
                ChatDetailView(
                    chat: chat, currentUserID: me.uid, store: chatStore,
                    navigationTitle: selectedTitle,
                    threadID: navigation.conversation.threadID,
                    initialPosition: .message(navigation.messageID),
                    onOpenThread: { openThread($0, in: chat) }
                )
                .id(navigation.id)
            } else if navigation.failed {
                ChahuaRecoverableErrorView(
                    title: "Couldn’t open notification",
                    message: "Check your connection and try again.",
                    retryTitle: "Try again",
                    onRetry: retryNotification)
            } else {
                ChahuaLoadingView(title: "Loading conversation")
            }
        } else if let conversation = selectedConversation {
            detailView(conversation)
        } else {
            ChahuaEmptyStateView(
                title: "Select a conversation",
                message: "Choose a chat from the list to start reading.",
                systemImage: "bubble.left.and.bubble.right"
            )
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private func detailView(_ conversation: ConversationListItem) -> some View {
        switch conversation {
        case .chat(let chat):
            ChatDetailView(
                chat: chat, currentUserID: me.uid, store: chatStore,
                onOpenThread: { openThread($0, in: chat) }
            )
            .id(conversation.id)
        case .thread(let thread):
            ThreadDetailView(thread: thread, currentUserID: me.uid, store: chatStore)
                .id(conversation.id)
        }
    }

    @ViewBuilder private func threadDestination(_ key: ConversationKey) -> some View {
        if let thread = openedThread, thread.key == key {
            ChatDetailView(
                chat: thread.chat, currentUserID: me.uid, store: chatStore,
                navigationTitle: thread.title, threadID: thread.rootID,
                initialPosition: thread.initialMessageID.map(TimelineInitialPosition.message)
                    ?? .liveEdge
            )
            .id(thread.id)
        }
    }

    private func openThread(_ message: MessageResponse, in chat: ChatListItem) {
        guard !isSigningOut, !message.isDeleted, message.chatId == chat.id else { return }
        let preview = messagePreview(message.replyPreview)
        pushThread(
            ThreadNavigation(
                chat: chat, rootID: message.id.description,
                title: preview.isEmpty ? AppLanguage.localized("Thread") : preview,
                root: message))
    }

    private func pushThread(_ thread: ThreadNavigation) {
        openedThread = thread
        #if os(macOS)
            withAnimation(nil) { threadPath = [thread.key] }
        #else
            withAnimation { threadPath = [thread.key] }
        #endif
    }

    private func popThread() {
        #if os(macOS)
            withAnimation(nil) { threadPath.removeAll() }
        #else
            withAnimation { threadPath.removeAll() }
        #endif
    }

    private var infoAction: (() -> Void)? {
        if let key = headerThreadKey, threadInfoAction?.conversation == key {
            return threadInfoAction?.perform
        }
        guard threadPath.isEmpty, let chat = selectedInfoChat else { return nil }
        return {
            guard groupPath.isEmpty, !isSigningOut else { return }
            withAnimation { groupPath.append(.info(chat)) }
        }
    }

    /// The selected group or DM, whose info page the header opens; threads have none.
    private var selectedInfoChat: ChatListItem? {
        guard selectedConversationID?.threadID == nil else { return nil }
        let chat: ChatListItem?
        if let navigationChat = messageNavigation?.chat {
            chat = navigationChat
        } else if case .chat(let selected) = selectedConversation {
            chat = selected
        } else {
            chat = nil
        }
        return chat
    }

    /// The chat searched from the visible conversation; threads search their parent chat.
    private var searchableChat: ChatListItem? {
        if let chat = messageNavigation?.chat { return chat }
        switch selectedConversation {
        case .chat(let chat):
            return chat
        case .thread(let thread):
            return chatStore.state.chats.first { $0.id == thread.chatId }
                ?? chatStore.state.archivedChats.first { $0.id == thread.chatId }
        case nil:
            return nil
        }
    }

    private var searchAction: (() -> Void)? {
        guard let chat = searchableChat else { return nil }
        return { openMessageSearch(in: chat) }
    }

    private func openMessageSearch(in chat: ChatListItem) {
        guard !isSigningOut else { return }
        if messageSearch?.chat.id != chat.id {
            let store = chatStore
            let chatID = chat.id
            messageSearch = MessageSearchSession(
                chat: chat,
                model: MessageSearchModel(chatID: chatID) { query in
                    try await store.searchMessages(chatID: chatID, query: query)
                })
        }
        guard groupPath.last != .search(chat) else { return }
        withAnimation { groupPath.append(.search(chat)) }
    }

    /// Leaves the retained search page and opens the result in its chat or thread.
    private func openSearchResult(_ message: MessageResponse) {
        guard let chat = messageSearch?.chat else { return }
        openMessageTarget(message, in: chat)
    }

    private func openMessageTarget(_ message: MessageResponse, in chat: ChatListItem) {
        guard !isSigningOut, message.chatId == chat.id else { return }
        groupPath.removeAll()
        let chatKey = ConversationKey(chatID: chat.id, threadID: nil)
        guard let rootID = message.replyRootId else {
            threadPath.removeAll()
            openedThread = nil
            messageNavigation = MessageNavigation(searchResult: message, in: chat, userID: me.uid)
            selectedConversationID = chatKey
            return
        }
        // Keep the parent chat underneath, so Back leaves the thread for its chat.
        if selectedConversationID != chatKey {
            if messageNavigation?.conversation != chatKey { messageNavigation = nil }
            selectedConversationID = chatKey
        }
        let subscribedRoot = (chatStore.state.threads + chatStore.state.archivedThreads).first {
            $0.chatId == chat.id && $0.threadRootMessage.id.description == rootID
        }
        let preview = subscribedRoot.map { messagePreview($0.threadRootMessage) }
        pushThread(
            ThreadNavigation(
                chat: chat, rootID: rootID,
                title: preview.flatMap { $0.isEmpty ? nil : $0 } ?? AppLanguage.localized("Thread"),
                initialMessageID: message.id))
    }

    @ViewBuilder
    private func groupDestination(_ route: GroupRoute) -> some View {
        Group {
            switch route {
            case .info(let chat):
                GroupInfoView(
                    chat: chat, currentUserID: me.uid, store: chatStore,
                    onLeave: {
                        if selectedConversationID?.chatID == chat.id { selectConversation(nil) }
                    },
                    onSearch: { openMessageSearch(in: chat) },
                    onOpenMessage: { groupPath.append(.source(chat, $0)) },
                    onOpenThread: { groupPath.append(.thread(chat, $0)) }
                )
                .id(chat.id)
            case .search(let chat):
                if let session = messageSearch, session.chat.id == chat.id {
                    MessageSearchView(model: session.model, onSelect: openSearchResult)
                }
            case .source(let chat, let message):
                ChatDetailView(
                    chat: chat, currentUserID: me.uid, store: chatStore,
                    threadID: message.replyRootId, initialPosition: .message(message.id),
                    onOpenThread: { groupPath.append(.thread(chat, $0)) })
            case .thread(let chat, let root):
                ChatDetailView(
                    chat: chat, currentUserID: me.uid, store: chatStore,
                    navigationTitle: AppLanguage.localized("Thread"),
                    threadID: root.id.description, initialPosition: .liveEdge,
                    onOpenThread: { groupPath.append(.thread(chat, $0)) })
            }
        }
        // Native destinations must not inherit the timeline's floating-header inset.
        .environment(\.chatHeaderInset, 0)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
        #endif
    }

    private var accountButton: some View {
        Button {
            setSettingsPresented(true)
        } label: {
            accountAvatar
        }
    }

    @ViewBuilder
    private var accountAvatar: some View {
        let avatar = AvatarView(
            url: me.avatarUrl.flatMap(URL.init(string:)),
            displayName: me.username,
            diameter: accountAvatarDiameter
        )
        .accessibilityLabel("Settings")
        #if os(iOS)
            if usesAccountHero {
                avatar.modifier(AccountAvatarEndpoint(role: .source))
            } else {
                avatar
            }
        #else
            avatar
        #endif
    }

    private var creationButton: some View {
        Menu {
            if canCreateGroup {
                Button("Create Group", systemImage: "person.3") {
                    guard canCreateGroup else { return }
                    feature = .createGroup
                }
            }
            Button("Add Friend", systemImage: "person.badge.plus") { feature = .addFriend }
            Button("Join with Link", systemImage: "link") { feature = .joinGroup("") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("New conversation")
        .help("New conversation")
    }

    private var canCreateGroup: Bool {
        guard let profile = chatStore.currentUserProfile, profile.uid == me.uid else {
            return false
        }
        return profile.permissions.contains("permission.all")
            || profile.permissions.contains("chat.create")
    }

    @ViewBuilder
    private func featureDestination(_ destination: FeatureDestination) -> some View {
        switch destination {
        case .addFriend:
            SocialDirectoryView(
                currentUserID: me.uid, store: chatStore, usersOnly: true,
                onOpenChat: openChat, onOpenProfile: openProfile)
        case .createGroup:
            CreateGroupView(store: chatStore, onOpenChat: openChat)
        case .joinGroup(let code):
            JoinGroupView(store: chatStore, initialCode: code, onOpenChat: openChat)
        case .profile(let uid):
            UserProfileView(
                uid: uid, currentUserID: me.uid, store: chatStore,
                isPresentedAsRoot: true, onOpenChat: openChat)
        }
    }

    private func openProfile(_ uid: Int32) {
        if feature == .profile(uid) {
            profilePath.removeAll()
        } else if let index = profilePath.firstIndex(of: uid) {
            profilePath = Array(profilePath.prefix(through: index))
        } else if feature == nil {
            guard listPath.last != .friendRequests(.profile(uid)) else { return }
            feature = .profile(uid)
        } else {
            profilePath.append(uid)
        }
    }

    private func openChat(_ chat: ChatListItem) {
        chatStore.retainChatForNavigation(chat)
        feature = nil
        profilePath.removeAll()
        showsSettings = false
        let conversation = ConversationKey(chatID: chat.id, threadID: nil)
        if selectedConversationID == conversation {
            // Pop back to the existing main timeline, including its message anchor,
            // view identity and composer, rather than selecting it again.
            if isBrowsingFriendRequests {
                listPath = isBrowsingArchived ? [.archive] : []
            }
            groupPath.removeAll()
            threadPath.removeAll()
            openedThread = nil
            return
        }

        // A different chat (or a standalone thread's parent) belongs above its
        // own list, not above a stale friend-request/profile sidebar stack.
        let isArchived = chatStore.state.archivedChats.contains { $0.id == chat.id }
        if isArchived {
            if !isBrowsingArchived { archivedScope = selectedScope }
            listPath = [.archive]
        } else {
            listPath.removeAll()
        }
        selectConversation(conversation)
    }

    /// The picker prepares a draft, not a send. Resolve access before mutating
    /// navigation so a failed destination leaves both conversations' drafts intact.
    private func openForwardDestination(_ target: ConversationListItem) async throws -> Bool {
        guard !isSigningOut else { return false }
        let accountID = me.uid
        let info = try await chatStore.groupInfo(chatID: target.id.chatID)
        let parent = chatStore.groupChatSnapshot(info)
        let root: MessageResponse?
        if target.id.threadID != nil {
            root = try await chatStore.threadRoot(for: target.id)
            guard root?.isDeleted == false else { return false }
        } else {
            root = nil
        }
        try Task.checkCancellation()
        guard !isSigningOut, me.uid == accountID,
            chatStore.currentUserProfile?.uid == accountID
        else { return false }
        if visibleConversation == target.id, groupPath.isEmpty, feature == nil {
            return true
        }
        listPath.removeAll()
        openChat(parent)
        if let root { openThread(root, in: parent) }
        return selectedConversationID?.chatID == target.id.chatID
            && (root == nil || threadPath.last == target.id)
    }

    private func openSourceMessage(_ message: MessageResponse, in chat: ChatListItem) {
        feature = nil
        openMessageTarget(message, in: chat)
    }

    private func openIncomingURL(_ url: URL) async {
        let origin = AppConfiguration.applicationURL
        guard url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port else {
            navigationError = String(localized: "This link belongs to a different server.")
            return
        }
        if let link = MessagePermalink(url: url) {
            do {
                let (message, chat) = try await chatStore.resolveMessageLink(
                    chatID: link.chatID, messageID: link.messageID)
                try Task.checkCancellation()
                openSourceMessage(message, in: chat)
            } catch is CancellationError {
            } catch {
                navigationError = String(
                    localized: "This message is unavailable or you do not have access.")
            }
        } else if url.path.hasPrefix("/chats/join/"),
            let code = GroupInviteLink.code(from: url.absoluteString)
        {
            feature = .joinGroup(code)
        } else {
            navigationError = String(localized: "This link is not supported.")
        }
    }

    private func openVoiceSource(_ source: MessageResponse) async {
        do {
            let (message, chat) = try await chatStore.resolveMessageLink(
                chatID: source.chatId, messageID: source.id)
            try Task.checkCancellation()
            openSourceMessage(message, in: chat)
        } catch is CancellationError {
        } catch {
            navigationError = String(
                localized: "This message is unavailable or you do not have access.")
        }
    }

    private var settings: some View {
        NotificationSettingsView(
            notifications: notifications, chatStore: chatStore,
            me: me, isSigningOut: isSigningOut,
            onSignOut: onSignOut, onOpenChat: openChat,
            onOpenSource: { message, chat in
                showsSettings = false
                openSourceMessage(message, in: chat)
            },
            usesHeroLayout: usesAccountHero,
            onClose: usesAccountHero ? { setSettingsPresented(false) } : nil)
    }

    private func setSettingsPresented(_ presented: Bool) {
        if presented && usesAccountHero { listPresentation.dismissSearchKeyboard() }
        showsSettings = presented
    }

    private var usesAccountHero: Bool {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .phone
        #else
            false
        #endif
    }

    private var selectedTitle: String {
        if let navigation = messageNavigation {
            if navigation.conversation.threadID != nil {
                return selectedConversation?.title ?? AppLanguage.localized("Thread")
            }
            return navigation.chat?.chatDisplayName ?? AppLanguage.localized("Loading conversation")
        }
        return selectedConversation?.title ?? ""
    }

    /// The thread whose title bar is visible, opened from a timeline, the thread
    /// list, a notification, or search; `nil` while a chat is visible.
    private var headerThreadKey: ConversationKey? {
        if let key = threadPath.last { return key }
        return selectedConversationID?.threadID == nil ? nil : selectedConversationID
    }

    /// Threads keep their composite identity beside the title, separate from subscription controls.
    private func headerLeading(for key: ConversationKey?) -> ThreadHeaderAvatar? {
        guard let key, key.threadID != nil else { return nil }
        let parent =
            chatStore.state.chats.first { $0.id == key.chatID }
            ?? chatStore.state.archivedChats.first { $0.id == key.chatID }
            ?? (openedThread?.key == key ? openedThread?.chat : nil)
            ?? (messageNavigation?.chat?.id == key.chatID ? messageNavigation?.chat : nil)
        return ThreadHeaderAvatar(
            key: key, parent: parent, store: chatStore, currentUserID: me.uid,
            diameter: ChatFloatingHeader<EmptyView>.avatarDiameter,
            root: openedThread?.key == key ? openedThread?.root : nil)
    }

    /// Threads show their subscription control where chats show their avatar.
    @ViewBuilder private func headerTrailing(for key: ConversationKey?) -> some View {
        if let key, key.threadID != nil, let model = threadSubscription, model.key == key {
            ThreadSubscriptionMenu(model: model)
        } else {
            selectedAvatar
        }
    }

    @ViewBuilder private var selectedAvatar: some View {
        if let conversation = selectedConversation {
            ConversationAvatarView(
                item: conversation, store: chatStore, currentUserID: me.uid,
                diameter: ChatFloatingHeader<EmptyView>.avatarDiameter)
        } else if let chat = messageNavigation?.chat {
            AvatarView(
                url: chat.chatAvatarURL, displayName: chat.chatDisplayName,
                diameter: ChatFloatingHeader<EmptyView>.avatarDiameter,
                isOnline: ChatPresenceDisplay.isOnline(chat, in: chatStore.state))
        }
    }

    /// The app-icon badge minus the chat on screen (or a thread's parent chat).
    private var backBadgeCount: Int {
        chatStore.state.unreadBadgeCount(excludingChatID: selectedConversationID?.chatID)
    }

    private var headerSubtitle: String? {
        ChatPresenceDisplay.subtitle(for: selectedInfoChat, in: chatStore.state)
    }

    private var headerChatIsMuted: Bool {
        guard selectedConversationID?.threadID == nil else { return false }
        return searchableChat?.notificationMuted(defaults: chatStore.state.notificationDefaults)
            == true
    }

    private var visibleConversation: ConversationKey? {
        guard isVisible, scenePhase == .active, !showsSettings,
            !isSigningOut, groupPath.isEmpty
        else { return nil }
        if let key = threadPath.last { return key }
        if let navigation = messageNavigation {
            return navigation.chat == nil ? nil : navigation.conversation
        }
        return selectedConversation?.id
    }

    private func reportVisibleConversation() {
        notifications.setVisibleConversation(
            sceneID: notificationSceneID, conversation: visibleConversation)
    }

    private func claimNotification() {
        guard scenePhase == .active, !isSigningOut,
            let route = notifications.takeNavigation()
        else { return }
        // Taking is synchronous across windows; keep the route while the
        // separate metadata task runs, including across cancellation/retry.
        groupPath.removeAll()
        threadPath.removeAll()
        openedThread = nil
        listPath.removeAll()
        messageNavigation = MessageNavigation(notification: route, userID: me.uid)
        showsSettings = false
        retainMessageSearch(forChatID: route.chatID)
        selectedConversationID = route.conversation
    }

    private func selectConversation(_ conversation: ConversationKey?) {
        groupPath.removeAll()
        threadPath.removeAll()
        openedThread = nil
        messageNavigation = nil
        retainMessageSearch(forChatID: conversation?.chatID)
        selectedConversationID = conversation
    }

    /// Search results survive only while their chat (or one of its threads) stays selected.
    private func retainMessageSearch(forChatID chatID: String?) {
        if messageSearch?.chat.id != chatID { messageSearch = nil }
    }

    private func retryNotification() {
        guard messageNavigation?.userID == me.uid, !isSigningOut else { return }
        messageNavigation?.failed = false
        messageNavigation?.requestID = UUID()
    }

    private func resolveNotification() async {
        guard let navigation = messageNavigation,
            let route = navigation.notificationRoute,
            navigation.userID == me.uid, !isSigningOut,
            navigation.chat == nil
        else { return }
        do {
            let chat = try await chatStore.chatForNotification(route)
            try Task.checkCancellation()
            guard messageNavigation?.requestID == navigation.requestID else { return }
            messageNavigation?.chat = chat
        } catch is CancellationError {
            // Keep the claimed route so a reappearing shell can resume loading.
        } catch {
            guard !Task.isCancelled,
                messageNavigation?.requestID == navigation.requestID
            else { return }
            messageNavigation?.failed = true
        }
    }

    private var accountAvatarDiameter: CGFloat { 32 }

    private var selectedConversation: ConversationListItem? {
        guard let selectedConversationID else { return nil }
        if let threadID = selectedConversationID.threadID {
            let matches: (ThreadListItem) -> Bool = {
                $0.chatId == selectedConversationID.chatID
                    && $0.threadRootMessage.id.description == threadID
            }
            return
                (chatStore.state.threads.first(where: matches)
                ?? chatStore.state.archivedThreads.first(where: matches)).map(
                    ConversationListItem.thread)
        }
        return
            (chatStore.state.chats.first { $0.id == selectedConversationID.chatID }
            ?? chatStore.state.archivedChats.first { $0.id == selectedConversationID.chatID }).map(
                ConversationListItem.chat)
    }

}
