import ChahuaAPI
import SwiftUI

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
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private enum NavigationRoute: Hashable {
        case archive
        case conversation(ConversationKey)
        case group(GroupRoute)
    }

    private enum GroupRoute: Hashable {
        case info(ChatListItem)
        case search(ChatListItem)
    }

    private var isBrowsingArchived: Bool { listPath.last == .archive }

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
            archivedScope = .messages
        }
        .onChange(of: isSigningOut) { _, signingOut in
            if signingOut {
                selectConversation(nil)
                listPath.removeAll()
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
                get: { showsSettings && !usesFullScreenSettings },
                set: { showsSettings = $0 }
            )
        ) {
            #if os(macOS)
                settings
                    .frame(minWidth: 760, idealWidth: 880, minHeight: 540, idealHeight: 640)
            #else
                settings
                    .frame(minWidth: 480, idealWidth: 560, minHeight: 520, idealHeight: 640)
            #endif
        }
        #if os(iOS)
            .fullScreenCover(
                isPresented: Binding(
                    get: { showsSettings && usesFullScreenSettings },
                    set: { showsSettings = $0 }
                )
            ) {
                settings
            }
        #endif
    }

    private var adaptiveLayout: some View {
        ChatSplitLayout(hasSelection: selectedConversationID != nil) { _ in
            #if os(iOS)
                // Archive pushes within the sidebar without changing the split detail selection.
                listNavigation(includesDetail: false)
            #else
                // macOS switches list content immediately; only iOS uses a native push.
                chatList(archived: isBrowsingArchived)
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
                            trailingIsControl: headerThreadKey != nil,
                            backBadgeCount: backBadgeCount
                        ) {
                            headerTrailing(for: headerThreadKey)
                        }
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
                                .background(ArchiveEdgeBackGesture())
                        case .conversation(let key):
                            Group {
                                if openedThread?.key == key {
                                    threadDestination(key)
                                } else {
                                    detailContent
                                }
                            }
                            .modifier(
                                ChatPhoneDetailHeader(
                                    title: openedThread?.key == key
                                        ? openedThread?.title ?? AppLanguage.localized("Thread")
                                        : selectedTitle,
                                    subtitle: key.threadID == nil ? headerSubtitle : nil,
                                    isMuted: key.threadID == nil && headerChatIsMuted,
                                    onOpenInfo: key.threadID == nil ? infoAction : nil,
                                    onSearch: searchAction,
                                    trailingIsControl: key.threadID != nil,
                                    backBadgeCount: backBadgeCount
                                ) {
                                    headerTrailing(for: key)
                                })
                        case .group(let route):
                            groupDestination(route)
                        }
                    }
            }
        }

        private var phonePath: Binding<[NavigationRoute]> {
            Binding(
                get: {
                    var path = listPath
                    if let selectedConversationID {
                        path.append(.conversation(selectedConversationID))
                        path.append(contentsOf: threadPath.map(NavigationRoute.conversation))
                        path.append(contentsOf: groupPath.map(NavigationRoute.group))
                    }
                    return path
                },
                set: { path in
                    listPath = path.first == .archive ? [.archive] : []
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
            chats: archived ? chatStore.state.archivedChats : chatStore.state.chats,
            threads: archived ? chatStore.state.archivedThreads : chatStore.state.threads,
            archived: archived, showThreadsInMessages: showThreadsInMessages)
        let list = ChatListView(
            store: chatStore,
            drafts: chatStore.drafts,
            currentUserID: me.uid,
            scope: scope.wrappedValue,
            archivedMode: archived,
            showThreadsInMessages: showThreadsInMessages,
            onOpenArchived: openArchived,
            badgeColor: unreadBadgeColor,
            selectedConversationID: selectedConversationID,
            onSelectConversation: { selectConversation($0.id) }
        )
        #if os(iOS)
            return GeometryReader { geometry in
                // One custom toolbar item owns the avatar/picker spacing. Give the
                // container an explicit width: UIKit otherwise measures its flexible
                // segmented control at zero inside the horizontal stack.
                let picker = ConversationScopePicker(
                    selection: scope, badges: badges, badgeColor: unreadBadgeColor
                )
                .frame(
                    minWidth: 0,
                    maxWidth: max(
                        0, geometry.size.width - (archived ? 96 : accountAvatarDiameter + 40)))
                let header = HStack(spacing: 8) {
                    accountButton
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: true))
                        .accessibilityLabel("Account")
                    picker
                }
                .buttonStyle(.plain)
                .frame(width: max(0, geometry.size.width - 32))
                list
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar {
                        // Keep the avatar and picker in one item so native toolbar
                        // group spacing cannot add an extra gap in split columns.
                        if #available(iOS 26, *) {
                            ToolbarItem(placement: .topBarTrailing) {
                                if archived { picker } else { header }
                            }
                            .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .topBarTrailing) {
                                if archived { picker } else { header }
                            }
                        }
                    }
            }
        #else
            return VStack(spacing: 0) {
                ConversationListHeader(
                    selection: scope, badges: badges,
                    badgeColor: unreadBadgeColor, onBack: archived ? { closeArchived() } : nil
                ) { accountButton }
                list
            }
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
                title: preview.isEmpty ? AppLanguage.localized("Thread") : preview))
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
        guard !isSigningOut, let chat = messageSearch?.chat, message.chatId == chat.id else {
            return
        }
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
                    onSearch: { openMessageSearch(in: chat) }
                )
                .id(chat.id)
            case .search(let chat):
                if let session = messageSearch, session.chat.id == chat.id {
                    MessageSearchView(model: session.model, onSelect: openSearchResult)
                }
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
            showsSettings = true
        } label: {
            AvatarView(
                url: me.avatarUrl.flatMap(URL.init(string:)),
                displayName: me.username,
                diameter: accountAvatarDiameter
            )
            .accessibilityLabel("Account")
        }
    }

    private var settings: some View {
        NotificationSettingsView(
            notifications: notifications, chatStore: chatStore,
            me: me, isSigningOut: isSigningOut,
            onSignOut: onSignOut)
    }

    private var usesFullScreenSettings: Bool {
        #if os(iOS)
            horizontalSizeClass == .compact
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
                diameter: ChatFloatingHeader<EmptyView>.avatarDiameter)
        }
    }

    /// The app-icon badge minus the chat on screen (or a thread's parent chat).
    private var backBadgeCount: Int {
        chatStore.state.unreadBadgeCount(excludingChatID: selectedConversationID?.chatID)
    }

    /// Placeholder until the server reports member counts and presence.
    private var headerSubtitle: String? {
        switch selectedInfoChat?.kind {
        case .group: AppLanguage.localized("— members, — online")
        case .dm: AppLanguage.localized("last seen —")
        case nil: nil
        }
    }

    private var headerChatIsMuted: Bool {
        guard selectedConversationID?.threadID == nil,
            let mutedUntil = searchableChat?.mutedUntil
        else { return false }
        return mutedUntil > Date()
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

    private var accountAvatarDiameter: CGFloat {
        #if os(iOS)
            32
        #else
            26
        #endif
    }

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
