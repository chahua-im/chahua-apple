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
    @State private var listPath: [NavigationRoute] = []
    @State private var selectedConversationID: ConversationKey?
    @State private var showsSettings = false
    @State private var isVisible = false
    @State private var notificationNavigation: NotificationNavigation?
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private enum NavigationRoute: Hashable {
        case archive
        case conversation(ConversationKey)
    }

    private var isBrowsingArchived: Bool { listPath.last == .archive }

    private struct NotificationNavigation {
        let route: PushNotificationRoute
        let userID: Int32
        var requestID = UUID()
        var chat: ChatListItem?
        var failed = false
    }

    private struct ThreadNavigation {
        let chat: ChatListItem
        let rootMessage: MessageResponse
        var key: ConversationKey { .init(chatID: chat.id, threadID: rootMessage.id) }
        var title: String {
            let preview = messagePreview(rootMessage.replyPreview)
            return preview.isEmpty ? String(localized: "Thread") : preview
        }
    }

    @State private var openedThread: ThreadNavigation?
    @State private var threadPath: [ConversationKey] = []

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
            guard let selectedConversationID, notificationNavigation == nil else { return }
            let loaded = selectedConversationID.threadID == nil
                ? (isBrowsingArchived ? state.archivedChatListLoadPhase : state.chatListLoadPhase) == .loaded
                : (isBrowsingArchived ? state.archivedThreadListLoadPhase : state.threadListLoadPhase) == .loaded
            if loaded && selectedConversation == nil { selectConversation(nil) }
        }
        .task(id: notifications.pendingNavigation?.id) { claimNotification() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { claimNotification() }
        }
        .task(id: notificationNavigation?.requestID) { await resolveNotification() }
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
        .onDisappear {
            isVisible = false
            notifications.setVisibleConversation(sceneID: notificationSceneID, conversation: nil)
        }
        .sheet(isPresented: Binding(
            get: { showsSettings && !usesFullScreenSettings },
            set: { showsSettings = $0 }
        )) {
            settings
                .frame(minWidth: 360, idealWidth: 460, minHeight: 420, idealHeight: 540)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { showsSettings && usesFullScreenSettings },
            set: { showsSettings = $0 }
        )) {
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
            Group {
                if let key = threadPath.last {
                    threadDestination(key)
                } else {
                    detailContent
                }
            }
            .modifier(ChatHeaderOverlay(isVisible: selectedConversationID != nil) {
                ChatFloatingHeader(
                    title: threadPath.isEmpty ? selectedTitle : openedThread?.title ?? String(localized: "Thread"),
                    onBack: !threadPath.isEmpty ? popThread : isSplit ? nil : { selectConversation(nil) },
                    onClose: isSplit && threadPath.isEmpty ? { selectConversation(nil) } : nil
                ) {
                    selectedAvatar
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            })
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
                        .modifier(ChatPhoneDetailHeader(
                            title: openedThread?.key == key ? openedThread?.title ?? String(localized: "Thread") : selectedTitle
                        ) {
                            selectedAvatar
                        })
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
                }
                return path
            },
            set: { path in
                listPath = path.first == .archive ? [.archive] : []
                let conversations = path.dropFirst(listPath.count).compactMap { route -> ConversationKey? in
                    guard case .conversation(let key) = route else { return nil }
                    return key
                }
                if conversations.first != selectedConversationID {
                    selectConversation(conversations.first)
                }
                threadPath = Array(conversations.dropFirst())
            }
        )
    }
    #endif

    private func chatList(archived: Bool) -> some View {
        let scope = archived ? $archivedScope : $selectedScope
        let badges = ConversationTabBadges(
            chats: archived ? chatStore.state.archivedChats : chatStore.state.chats,
            threads: archived ? chatStore.state.archivedThreads : chatStore.state.threads,
            archived: archived)
        let list = ChatListView(
            store: chatStore,
            drafts: chatStore.drafts,
            currentUserID: me.uid,
            scope: scope.wrappedValue,
            archivedMode: archived,
            onOpenArchived: openArchived,
            selectedConversationID: selectedConversationID,
            onSelectConversation: { selectConversation($0.id) }
        )
        #if os(iOS)
        return GeometryReader { geometry in
            // Toolbar custom views use intrinsic sizing rather than the list's
            // width proposal. Reserve the leading control and bar margins so the
            // same picker fits both the account button and native archive Back.
            // A fixed width would move it into the toolbar's overflow menu.
            let picker = ConversationScopePicker(selection: scope, badges: badges)
                .frame(minWidth: 0, maxWidth: max(0, geometry.size.width - 96))
            list
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    if !archived {
                        ToolbarItem(placement: .topBarLeading) {
                            accountButton
                                .labelStyle(.iconOnly)
                                .accessibilityLabel("Account")
                        }
                    }
                    // A segmented control must not participate in native title morphing.
                    if #available(iOS 26, *) {
                        ToolbarItem(placement: .topBarTrailing) {
                            picker
                        }
                        // The scope control already draws its own background.
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarTrailing) {
                            picker
                        }
                    }
                }
        }
        #else
        return VStack(spacing: 0) {
            ConversationListHeader(
                selection: scope, badges: badges,
                onBack: archived ? { closeArchived() } : nil
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
        if let navigation = notificationNavigation,
           navigation.route.conversation == selectedConversationID {
            if let chat = navigation.chat {
                ChatDetailView(
                    chat: chat, currentUserID: me.uid, store: chatStore,
                    navigationTitle: selectedTitle,
                    threadID: navigation.route.threadID,
                    initialPosition: .message(navigation.route.messageID),
                    onOpenThread: { openThread($0, in: chat) })
                    .id(navigation.route.id)
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
            ChatDetailView(chat: chat, currentUserID: me.uid, store: chatStore,
                           onOpenThread: { openThread($0, in: chat) })
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
                navigationTitle: thread.title, threadID: thread.rootMessage.id,
                initialPosition: .liveEdge)
                .id(key)
        }
    }

    private func openThread(_ message: MessageResponse, in chat: ChatListItem) {
        guard !isSigningOut, !message.isDeleted, message.chatId == chat.id else { return }
        let thread = ThreadNavigation(chat: chat, rootMessage: message)
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
            username: me.username, isSigningOut: isSigningOut,
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
        if let navigation = notificationNavigation {
            if navigation.route.threadID != nil {
                return selectedConversation?.title ?? String(localized: "Thread")
            }
            return navigation.chat?.chatDisplayName ?? String(localized: "Loading conversation")
        }
        return selectedConversation?.title ?? ""
    }

    @ViewBuilder private var selectedAvatar: some View {
        if let conversation = selectedConversation {
            ConversationAvatarView(
                item: conversation, store: chatStore, currentUserID: me.uid, diameter: 32)
        } else if let chat = notificationNavigation?.chat {
            AvatarView(url: chat.chatAvatarURL, displayName: chat.chatDisplayName, diameter: 32)
        }
    }

    private var visibleConversation: ConversationKey? {
        guard isVisible, scenePhase == .active, !showsSettings, !isSigningOut else { return nil }
        if let key = threadPath.last { return key }
        if let navigation = notificationNavigation {
            return navigation.chat == nil ? nil : navigation.route.conversation
        }
        return selectedConversation?.id
    }

    private func reportVisibleConversation() {
        notifications.setVisibleConversation(
            sceneID: notificationSceneID, conversation: visibleConversation)
    }

    private func claimNotification() {
        guard scenePhase == .active, !isSigningOut,
              let route = notifications.takeNavigation() else { return }
        // Taking is synchronous across windows; keep the route while the
        // separate metadata task runs, including across cancellation/retry.
        threadPath.removeAll()
        openedThread = nil
        listPath.removeAll()
        notificationNavigation = NotificationNavigation(route: route, userID: me.uid)
        showsSettings = false
        selectedConversationID = route.conversation
    }

    private func selectConversation(_ conversation: ConversationKey?) {
        threadPath.removeAll()
        openedThread = nil
        notificationNavigation = nil
        selectedConversationID = conversation
    }

    private func retryNotification() {
        guard notificationNavigation?.userID == me.uid, !isSigningOut else { return }
        notificationNavigation?.failed = false
        notificationNavigation?.requestID = UUID()
    }

    private func resolveNotification() async {
        guard let navigation = notificationNavigation,
              navigation.userID == me.uid, !isSigningOut,
              navigation.chat == nil else { return }
        do {
            let chat = try await chatStore.chatForNotification(navigation.route)
            try Task.checkCancellation()
            guard notificationNavigation?.requestID == navigation.requestID else { return }
            notificationNavigation?.chat = chat
        } catch is CancellationError {
            // Keep the claimed route so a reappearing shell can resume loading.
        } catch {
            guard !Task.isCancelled,
                  notificationNavigation?.requestID == navigation.requestID else { return }
            notificationNavigation?.failed = true
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
                $0.chatId == selectedConversationID.chatID && $0.threadRootMessage.id == threadID
            }
            return (chatStore.state.threads.first(where: matches)
                ?? chatStore.state.archivedThreads.first(where: matches)).map(ConversationListItem.thread)
        }
        return (chatStore.state.chats.first { $0.id == selectedConversationID.chatID }
            ?? chatStore.state.archivedChats.first { $0.id == selectedConversationID.chatID }).map(ConversationListItem.chat)
    }

}
