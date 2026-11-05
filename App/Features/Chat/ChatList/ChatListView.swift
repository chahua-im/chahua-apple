import ChahuaAPI
import Combine
import SwiftUI

#if os(iOS)
    private struct ConversationListBottomSafeAreaKey: EnvironmentKey {
        static let defaultValue: CGFloat? = nil
    }

    extension EnvironmentValues {
        /// NavigationStack resets inherited insets; preserve shell playback clearance.
        var conversationListBottomSafeArea: CGFloat? {
            get { self[ConversationListBottomSafeAreaKey.self] }
            set { self[ConversationListBottomSafeAreaKey.self] = newValue }
        }
    }
#endif

struct ChatListView: View {
    @Environment(\.isWideChatLayout) private var isWideChatLayout
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.system.rawValue
    @ObservedObject var store: ChatStore
    @ObservedObject var drafts: ChatDraftStore
    let currentUserID: Int32
    @Binding var scope: ConversationListScope
    var archivedMode = false
    var showThreadsInMessages = ConversationListPreferences.defaultShowThreadsInMessages
    var onOpenArchived: (() -> Void)?
    var onOpenFriendRequestHistory: (() -> Void)?
    var badgeColor = ConversationListPreferences.defaultUnreadBadgeColor
    var presentation: ConversationListPresentation? = nil
    let selectedConversationID: ConversationKey?
    let onSelectConversation: (ConversationListItem) -> Void
    @State private var isPullRefreshing = false
    @State private var revealedConversationID: ConversationKey?
    @State private var conversationStateConsumer = UUID()
    @State private var listSnapshotCache = ConversationListSnapshotCache()
    @State private var swipeActionCache = ConversationListSwipeActionCache()
    @State private var notificationChat: ChatListItem?
    @State private var archiveConfirmation: ArchiveConfirmation?
    @StateObject private var scrollScope = ConversationListScrollScope()
    @State private var searchText = ""
    @State private var isListVisible = false
    @State private var presentationGeneration = 0
    @FocusState private var isSearchFocused: Bool
    #if os(iOS)
        @Environment(\.conversationListBottomSafeArea) private var bottomSafeArea
    #endif
    #if os(macOS)
        @StateObject private var overlayScrollers = ChatListOverlayScrollerScope()
    #endif

    private struct LoadID: Equatable {
        let scope: ConversationListScope
        let archived: Bool
        let showThreadsInMessages: Bool
    }

    private struct ArchiveConfirmationContext: Equatable {
        let currentUserID: Int32
        let profileUserID: Int32?
        let storeID: ObjectIdentifier
        let list: LoadID
        let selectedConversationID: ConversationKey?
    }

    private struct ArchiveConfirmation {
        let conversation: ConversationKey
        let action: ConversationListAction
        let context: ArchiveConfirmationContext
    }

    private var archiveConfirmationContext: ArchiveConfirmationContext {
        .init(
            currentUserID: currentUserID, profileUserID: store.currentUserProfile?.uid,
            storeID: ObjectIdentifier(store),
            list: LoadID(
                scope: scope, archived: archivedMode, showThreadsInMessages: showThreadsInMessages),
            selectedConversationID: selectedConversationID)
    }

    private enum ListAlert {
        case archive(ArchiveConfirmation)
        case failure(String)
    }

    private var listAlert: ListAlert? {
        if let archiveConfirmation { return .archive(archiveConfirmation) }
        return store.listActionError.map(ListAlert.failure)
    }

    private var listAlertTitle: LocalizedStringKey {
        if case .archive(let confirmation) = listAlert {
            return confirmation.action == .unarchive
                ? "Unarchive conversation?" : "Archive conversation?"
        }
        return "Conversation actions"
    }

    private func dismissListAlert() {
        if archiveConfirmation != nil {
            archiveConfirmation = nil
        } else {
            store.listActionError = nil
        }
    }

    private var chatPhase: ChatListLoadPhase {
        archivedMode ? store.state.archivedChatListLoadPhase : store.state.chatListLoadPhase
    }

    private var threadPhase: ChatListLoadPhase {
        archivedMode ? store.state.archivedThreadListLoadPhase : store.state.threadListLoadPhase
    }

    private var includesThreads: Bool {
        scope.includesThreads(showThreadsInMessages: showThreadsInMessages)
    }

    private var hasArchivedConversations: Bool {
        (scope.includesChats
            && store.state.archivedChats.contains {
                scope == .messages || (scope == .groups && $0.kind == .group)
                    || (scope == .dms && $0.kind == .dm)
            }) || (includesThreads && !store.state.archivedThreads.isEmpty)
            || (scope.includesChats && store.state.archivedChatListLoadPhase == .failed)
            || (includesThreads && store.state.archivedThreadListLoadPhase == .failed)
    }

    var body: some View {
        #if os(iOS)
            GeometryReader { geometry in
                listContent(bottomInset: bottomSafeArea ?? geometry.safeAreaInsets.bottom)
            }
        #else
            listContent(bottomInset: 0)
        #endif
    }

    @ViewBuilder
    private func listContent(bottomInset: CGFloat) -> some View {
        #if os(macOS)
            // Native List scroll-offset restoration must not compete with header
            // safe-area insets. Give macOS chrome its own space above the viewport.
            VStack(spacing: 0) {
                if isWideChatLayout {
                    wideSearchHeader
                }
                conversationList(bottomInset: bottomInset)
            }
        #else
            conversationList(bottomInset: bottomInset)
        #endif
    }

    private var wideSearchHeader: some View {
        VStack(spacing: 0) {
            searchDrawer
            ConversationScopePicker(
                selection: $scope,
                badges: ConversationTabBadges(
                    summaries: store.state.conversationUnreadSummaries,
                    archived: archivedMode,
                    showThreadsInMessages: showThreadsInMessages),
                badgeColor: badgeColor
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func conversationList(bottomInset: CGFloat) -> some View {
        let snapshot = listSnapshotCache.snapshot(
            chats: archivedMode ? store.state.archivedChats : store.state.chats,
            threads: archivedMode ? store.state.archivedThreads : store.state.threads,
            scope: scope, archived: archivedMode, showThreadsInMessages: showThreadsInMessages,
            draftUpdatedAt: drafts.draftUpdatedAt, pendingPreviews: store.pendingListPreviews)
        let items = snapshot.items
        let language = AppLanguage(rawValue: languageRawValue) ?? .system
        let swipeActions = swipeActionCache.actions(language: language, locale: locale)
        let loadStatus = ConversationListLoadStatus(
            state: store.state, scope: scope, archivedMode: archivedMode,
            showThreadsInMessages: showThreadsInMessages,
            isPullRefreshing: isPullRefreshing, onRetry: { await performManualRefresh() }
        )
        ConversationListViewport {
            if !isWideChatLayout, !usesPrototypePull,
                scrollScope.isSearchRevealed && !isSearchPinned
            {
                Color.clear
                    .frame(height: ConversationListScrollScope.drawerHeight)
                    #if os(iOS)
                        .background(ConversationListScrollMarker(scope: scrollScope))
                    #endif
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
            }
            if loadStatus.isVisible {
                loadStatus
                    #if os(iOS)
                        .background(ConversationListScrollMarker(scope: scrollScope))
                    #endif
            }
            if !archivedMode, let onOpenArchived, hasArchivedConversations {
                Button(action: onOpenArchived) { archivedEntry }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("archived-conversations")
                    #if os(iOS)
                        .background(ConversationListScrollMarker(scope: scrollScope))
                    #endif
                    #if os(macOS)
                        .padding(.horizontal, usesDesktopDensity ? 8 : 0)
                        .padding(.bottom, usesDesktopDensity ? 2 : 0)
                    #else
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    #endif
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            // Match the PWA Friends list: records remain visible even with no pending requests.
            if !archivedMode, scope == .dms, let onOpenFriendRequestHistory {
                Button(action: onOpenFriendRequestHistory) { friendRequestHistoryEntry }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("friend-request-records")
                    #if os(iOS)
                        .background(ConversationListScrollMarker(scope: scrollScope))
                    #endif
                    #if os(macOS)
                        .padding(.horizontal, usesDesktopDensity ? 8 : 0)
                        .padding(.bottom, usesDesktopDensity ? 2 : 0)
                    #else
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    #endif
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if items.isEmpty && isLoaded {
                ChahuaEmptyStateView(
                    title: archivedMode ? "No archived conversations" : "No conversations",
                    message: archivedMode
                        ? "Archived conversations in this category will appear here."
                        : "Conversations in this category will appear here.",
                    systemImage: scope == .threads ? "text.bubble" : "bubble.left.and.bubble.right"
                )
                #if os(iOS)
                    .background(ConversationListScrollMarker(scope: scrollScope))
                #endif
            }
            ForEach(items) { item in
                ConversationListSwipeRow(
                    row: ConversationListRow(
                        item: item,
                        draft: drafts.draftText(chatID: item.id.chatID, threadID: item.id.threadID),
                        pending: store.pendingListPreviews[item.id],
                        store: store, currentUserID: currentUserID,
                        isSelected: selectedConversationID == item.id, badgeColor: badgeColor,
                        localization: swipeActions),
                    selectionColor: selectionColor, archived: archivedMode,
                    pendingAction: store.pendingListAction(for: item.id),
                    actions: swipeActions, revealedID: $revealedConversationID,
                    onSelect: { onSelectConversation(item) },
                    onAction: { performSwipeAction($0, on: item) }
                )
                #if os(iOS)
                    .background(ConversationListScrollMarker(scope: scrollScope))
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                #else
                    .padding(.horizontal, usesDesktopDensity ? 8 : 0)
                    .padding(.bottom, usesDesktopDensity ? 2 : 0)
                #endif
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            #if os(iOS)
                .listSectionSeparator(.hidden, edges: .top)
            #endif
        }
        #if os(macOS)
            // Preserve sidebar spacing without List's per-cell hosting/sizing.
            .contentMargins(.top, usesDesktopDensity ? 2 : 0, for: .scrollContent)
            .contentMargins(.bottom, 0, for: .scrollContent)
        #else
            .contentMargins(.vertical, 0, for: .scrollContent)
        #endif
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .safeAreaPadding(.bottom, bottomInset)
        #if os(iOS)
            .scrollContentBackground(.hidden)
        #endif
        #if os(macOS)
            .background(
                ConversationListViewportMarker(
                    scrollScope: scrollScope, scrollerScope: overlayScrollers))
        #else
            .background(ConversationListScrollMarker(scope: scrollScope, keepsScopeAlive: true))
            .background(alignment: .top) {
                if usesPrototypePull {
                    IOSConversationListPullRefreshIndicator(
                        pullDistance: scrollScope.pullDistance,
                        isRefreshing: scrollScope.isRefreshing,
                        searchHeight: prototypeSearchHeight)
                }
            }
        #endif
        #if os(iOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                if isWideChatLayout {
                    wideSearchHeader
                } else if !usesPrototypePull, scrollScope.isSearchRevealed, isSearchPinned {
                    Color.clear.frame(height: searchDrawerHeight)
                }
            }
        #else
            .safeAreaInset(edge: .top, spacing: 0) {
                if !isWideChatLayout, scrollScope.isSearchRevealed, isSearchPinned {
                    Color.clear.frame(height: searchDrawerHeight)
                }
            }
        #endif
        .overlay(alignment: .top) {
            #if os(iOS)
                if usesPrototypePull {
                    IOSConversationListPullSearchPresentation(
                        pullDistance: scrollScope.pullDistance,
                        searchHeight: prototypeSearchHeight
                    ) {
                        searchControls
                    } feedback: {
                        if !searchText.isEmpty {
                            searchUnavailableFeedback
                                .padding(.horizontal, 16)
                        }
                    }
                    .allowsHitTesting(scrollScope.isSearchRevealed)
                    .accessibilityIdentifier("conversation-search-drawer")
                }
            #endif
            if !isWideChatLayout, !usesPrototypePull,
                scrollScope.isSearchRevealed || scrollScope.pullDistance > 0
            {
                searchDrawer
                    .frame(
                        height: scrollScope.isSearchRevealed
                            ? searchDrawerHeight : scrollScope.pullDistance,
                        alignment: .top
                    )
                    .clipped()
                    .offset(y: isSearchPinned ? 0 : -scrollScope.drawerOffset)
                    .allowsHitTesting(
                        scrollScope.isSearchRevealed
                            && (isSearchPinned
                                || scrollScope.drawerOffset
                                    < ConversationListScrollScope.drawerHeight)
                    )
            }
        }
        .clipped()
        #if os(iOS)
            // Keep the viewport edge-to-edge, but reserve the original safe area
            // (including playback chrome) inside the scrollable content.
            .ignoresSafeArea(.container, edges: .bottom)
        #endif
        .preference(key: ConversationListRefreshingKey.self, value: isPullRefreshing)
        .accessibilityActions {
            Button("Search conversations") { revealSearch() }
            Button("Refresh conversations") { Task { await performManualRefresh() } }
        }
        .background {
            HStack(spacing: 0) {
                Button("Search conversations") {
                    revealSearch()
                    isSearchFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Refresh conversations") { Task { await performManualRefresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .disabled(!isListVisible)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear { configureListPresentation() }
        .onReceive(
            presentation?.requests.eraseToAnyPublisher()
                ?? Empty<ConversationListPresentation.Request, Never>().eraseToAnyPublisher()
        ) { request in
            switch request {
            case .reset:
                isSearchFocused = false
                searchText = ""
                presentationGeneration = presentation?.resetGeneration ?? 0
                scrollScope.reset()
                scrollScope.isSearchPinned = isSearchPinned
            case .revealSearch:
                if isListVisible { revealSearch() }
            case .dismissSearchKeyboard:
                isSearchFocused = false
            }
        }
        .onChange(of: isSearchPinned) { _, pinned in scrollScope.isSearchPinned = pinned }
        .onChange(of: usesPrototypePull) { _, enabled in
            scrollScope.prototypePullEnabled = enabled
        }
        .onChange(of: prototypeSearchAdditionalHeight) { _, height in
            scrollScope.prototypeSearchAdditionalHeight = height
        }
        .onChange(of: scope) { _, _ in resetScopePresentation() }
        .onChange(of: archivedMode) { _, _ in resetScopePresentation() }
        .onChange(of: currentUserID) { _, _ in resetScopePresentation(preservingSearch: false) }
        .onChange(of: selectedConversationID) { _, _ in revealedConversationID = nil }
        .onChange(of: archiveConfirmationContext) { _, _ in archiveConfirmation = nil }
        .onDisappear {
            isListVisible = false
            revealedConversationID = nil
            archiveConfirmation = nil
            scrollScope.onRefresh = nil
            scrollScope.detach()
            store.removeConversationStateScope(for: conversationStateConsumer)
        }
        .task(id: snapshot.conversationRefs) {
            store.setConversationStateScope(
                snapshot.conversationRefs, for: conversationStateConsumer)
        }
        .task(
            id: LoadID(
                scope: scope, archived: archivedMode, showThreadsInMessages: showThreadsInMessages
            )
        ) { await loadScope() }
        .sheet(item: $notificationChat) { chat in
            NavigationStack {
                ChatNotificationSettingsView(store: store, chat: chat)
            }
            .frame(minWidth: 320, minHeight: 420)
        }
        .alert(
            listAlertTitle,
            isPresented: Binding(
                get: { listAlert != nil },
                set: { if !$0 { dismissListAlert() } }),
            presenting: listAlert
        ) { alert in
            switch alert {
            case .archive(let confirmation):
                if confirmation.action == .archive {
                    Button("Archive") { confirmArchiveAction(confirmation) }
                } else {
                    Button("Unarchive") { confirmArchiveAction(confirmation) }
                }
                Button("Cancel", role: .cancel) { archiveConfirmation = nil }
            case .failure:
                Button("OK") { store.listActionError = nil }
            }
        } message: { alert in
            if case .failure(let message) = alert { Text(message) }
        }
    }

    private var isSearchPinned: Bool {
        isWideChatLayout || isSearchFocused || !searchText.isEmpty
    }

    private var usesPrototypePull: Bool {
        #if os(iOS)
            !isWideChatLayout
        #else
            false
        #endif
    }

    private var prototypeSearchAdditionalHeight: CGFloat {
        usesPrototypePull && !searchText.isEmpty ? 32 : 0
    }

    private var prototypeSearchHeight: CGFloat {
        ConversationListScrollScope.prototypeDrawerHeight + prototypeSearchAdditionalHeight
    }

    private var usesDesktopDensity: Bool {
        ConversationListMetrics.usesDesktopDensity(isWide: isWideChatLayout)
    }

    private var searchControlHeight: CGFloat { usesDesktopDensity ? 28 : 40 }

    private var searchRowHeight: CGFloat {
        if usesDesktopDensity { return searchControlHeight + 10 }
        return isWideChatLayout
            ? searchControlHeight + 16 : ConversationListScrollScope.drawerHeight
    }

    private func revealSearch() {
        // Wide search is already visible; revealing a pull drawer would reset the list offset.
        if !isWideChatLayout { scrollScope.revealSearch() }
    }

    private var searchDrawerHeight: CGFloat {
        ConversationListScrollScope.drawerHeight + (searchText.isEmpty ? 0 : 32)
    }

    private var searchDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchControls
                .padding(.horizontal, 12)
                .frame(height: searchRowHeight, alignment: usesDesktopDensity ? .top : .center)
            if !searchText.isEmpty {
                searchUnavailableFeedback
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !isWideChatLayout { Rectangle().fill(.background) }
        }
        .accessibilityIdentifier("conversation-search-drawer")
    }

    private var searchUnavailableFeedback: some View {
        Text("Search is not available yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 32, alignment: .topLeading)
            .accessibilityIdentifier("conversation-search-unavailable")
    }

    private var searchControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: usesDesktopDensity ? 6 : 8) {
                Image(systemName: "magnifyingglass")
                    .font(usesDesktopDensity ? .system(size: 14) : .body)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(
                    isWideChatLayout
                        ? LocalizedStringKey(usesDesktopDensity ? "Search (⌘K)" : "Search")
                        : LocalizedStringKey("Search chats, messages, people"),
                    text: $searchText
                )
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .accessibilityHint("Search is not available yet.")
            }
            .font(usesDesktopDensity ? .system(size: 13) : .body)
            .padding(.horizontal, usesDesktopDensity ? 8 : (usesPrototypePull ? 14 : 12))
            .frame(height: searchControlHeight)
            .background {
                if isWideChatLayout {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                } else {
                    Capsule().fill(searchControlFill)
                }
            }
            if isSearchFocused || !searchText.isEmpty {
                Button("Cancel") {
                    isSearchFocused = false
                    searchText = ""
                    if !isWideChatLayout { scrollScope.cancelSearch() }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .foregroundStyle(.blue)
            }
        }
    }

    private var searchControlFill: Color {
        #if os(iOS)
            if usesPrototypePull { return Color(uiColor: .tertiarySystemFill) }
        #endif
        return Color.secondary.opacity(0.1)
    }

    private func configureListPresentation() {
        isListVisible = true
        if let presentation, presentationGeneration != presentation.resetGeneration {
            isSearchFocused = false
            searchText = ""
            presentationGeneration = presentation.resetGeneration
        }
        scrollScope.prototypePullEnabled = usesPrototypePull
        scrollScope.prototypeSearchAdditionalHeight = prototypeSearchAdditionalHeight
        scrollScope.activate()
        scrollScope.presentation = presentation
        scrollScope.select(scope: scope, archived: archivedMode, currentUserID: currentUserID)
        scrollScope.isSearchPinned = isSearchPinned
        scrollScope.onRefresh = { Task { await performManualRefresh() } }
    }

    private func resetScopePresentation(preservingSearch: Bool = true) {
        revealedConversationID = nil
        // Scope changes preserve an active query; account changes must discard it.
        scrollScope.select(
            scope: scope, archived: archivedMode, currentUserID: currentUserID,
            preservingSearch: preservingSearch && isSearchPinned)
        if !preservingSearch {
            isSearchFocused = false
            searchText = ""
        }
        scrollScope.prototypeSearchAdditionalHeight = prototypeSearchAdditionalHeight
        scrollScope.isSearchPinned = isSearchPinned
        scrollScope.onRefresh = { Task { await performManualRefresh() } }
    }

    private func performManualRefresh() async {
        guard !isPullRefreshing else { return }
        isPullRefreshing = true
        scrollScope.isRefreshing = true
        defer {
            isPullRefreshing = false
            scrollScope.isRefreshing = false
        }
        await refreshScope()
    }

    private var archivedEntry: some View {
        let badges = ConversationTabBadges(
            summaries: store.state.conversationUnreadSummaries,
            archived: true, showThreadsInMessages: showThreadsInMessages)
        return HStack(
            spacing: usesDesktopDensity ? 10 : (isWideChatLayout ? 8 : ChahuaTheme.Spacing.medium)
        ) {
            AvatarFrame(
                diameter: ConversationListMetrics.avatarDiameter(isWide: isWideChatLayout)
            ) { _ in
                (usesDesktopDensity
                    ? Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
                    : ChahuaTheme.ChatList.primary)
                    .overlay {
                        Image(systemName: "archivebox")
                            .font(usesDesktopDensity ? .system(size: 20) : .title2)
                            .foregroundStyle(.white)
                    }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: usesDesktopDensity ? 3 : 4) {
                Text("Archived")
                    .font(usesDesktopDensity ? .system(size: 14, weight: .semibold) : .headline)
                Text("View archived chats and threads")
                    .modifier(ConversationListSubtitleStyle(isSelected: false))
            }
            Spacer(minLength: 8)
            if let label = badges.label(for: scope) {
                Text(label)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(badges.accessibilityValue(for: scope))
            }
        }
        .modifier(ConversationListRowLayout())
        .contentShape(Rectangle())
    }

    private var friendRequestHistoryEntry: some View {
        HStack(
            spacing: usesDesktopDensity ? 10 : (isWideChatLayout ? 8 : ChahuaTheme.Spacing.medium)
        ) {
            AvatarFrame(
                diameter: ConversationListMetrics.avatarDiameter(isWide: isWideChatLayout)
            ) { _ in
                ChahuaTheme.ChatList.primary
                    .overlay {
                        Image(systemName: "person.crop.circle.badge.clock")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: usesDesktopDensity ? 3 : 4) {
                Text("Friend Requests")
                    .font(usesDesktopDensity ? .system(size: 14, weight: .semibold) : .headline)
                Text("View friend request records")
                    .modifier(ConversationListSubtitleStyle(isSelected: false))
            }
            Spacer(minLength: 8)
        }
        .modifier(ConversationListRowLayout())
        .contentShape(Rectangle())
    }

    private var selectionColor: Color {
        guard usesDesktopDensity else { return ChahuaTheme.ChatList.primary }
        // Reference blue in light mode; a lighter blue retains contrast on dark glass.
        return colorScheme == .dark
            ? Color(red: 10 / 255, green: 106 / 255, blue: 225 / 255)
            : Color(red: 0, green: 98 / 255, blue: 209 / 255)
    }

    private func performSwipeAction(_ action: String, on item: ConversationListItem) {
        guard let action = ConversationListAction(rawValue: action) else { return }
        perform(action, on: item)
    }

    private var isLoaded: Bool {
        (!scope.includesChats || chatPhase == .loaded)
            && (!includesThreads || threadPhase == .loaded)
    }

    private func perform(_ action: ConversationListAction, on item: ConversationListItem) {
        guard store.pendingListAction(for: item.id) == nil else { return }
        revealedConversationID = nil
        if action == .notificationSettings, case .chat(let chat) = item {
            notificationChat = chat
            return
        }
        if action == .archive || action == .unarchive {
            archiveConfirmation = ArchiveConfirmation(
                conversation: item.id, action: action, context: archiveConfirmationContext)
            return
        }
        Task { await store.performListAction(action, conversation: item.id) }
    }

    private func confirmArchiveAction(_ confirmation: ArchiveConfirmation) {
        // SwiftUI may clear the presentation binding before invoking the button.
        // Validate the captured scope/account, not the now-dismissed UI state.
        guard confirmation.context == archiveConfirmationContext else { return }
        archiveConfirmation = nil
        Task {
            guard store.currentUserProfile?.uid == confirmation.context.currentUserID else {
                return
            }
            await store.performListAction(
                confirmation.action, conversation: confirmation.conversation)
        }
    }

    private func loadScope() async {
        async let chats: Void = loadChatsIfNeeded()
        async let threads: Void = loadThreadsIfNeeded()
        _ = await (chats, threads)
    }

    private func loadChatsIfNeeded() async {
        guard scope.includesChats else { return }
        if archivedMode {
            await store.loadArchivedChats()
        } else {
            async let active: Void = store.loadActiveChats()
            async let archived: Void = store.loadArchivedChats()
            _ = await (active, archived)
        }
    }

    private func loadThreadsIfNeeded() async {
        guard includesThreads else { return }
        if archivedMode {
            await store.loadArchivedThreads()
        } else {
            async let active: Void = store.loadActiveThreads()
            async let archived: Void = store.loadArchivedThreads()
            _ = await (active, archived)
        }
    }

    private func refreshScope() async {
        if archivedMode {
            await refreshArchivedScope()
        } else {
            async let active: Void = refreshActiveScope()
            async let archived: Void = refreshArchivedScope()
            _ = await (active, archived)
        }
    }

    private func refreshActiveScope() async {
        if scope == .messages && showThreadsInMessages {
            await store.refreshActiveConversations()
        } else if scope == .threads {
            await store.refreshActiveThreads()
        } else {
            await store.refreshActiveChats()
        }
    }

    private func refreshArchivedScope() async {
        if scope == .messages && showThreadsInMessages {
            await store.refreshArchivedConversations()
        } else if scope == .threads {
            await store.refreshArchivedThreads()
        } else {
            await store.refreshArchivedChats()
        }
    }
}

/// The selected scope has one presentation state even when multiple lists load independently.
struct ConversationListLoadStatus: View {
    let state: ChatState
    let scope: ConversationListScope
    var archivedMode = false
    var showThreadsInMessages = true
    var isPullRefreshing = false
    let onRetry: () async -> Void

    private var chatPhase: ChatListLoadPhase {
        archivedMode ? state.archivedChatListLoadPhase : state.chatListLoadPhase
    }

    private var threadPhase: ChatListLoadPhase {
        archivedMode ? state.archivedThreadListLoadPhase : state.threadListLoadPhase
    }

    private var includesThreads: Bool {
        scope.includesThreads(showThreadsInMessages: showThreadsInMessages)
    }

    private var connectionMessage: LocalizedStringKey? {
        switch state.realtimeStatus {
        case .idle, .connected: nil
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .unavailable: "Can’t connect right now. Retrying…"
        }
    }

    private var hasInitialFailure: Bool {
        (scope.includesChats && chatPhase == .failed)
            || (includesThreads && threadPhase == .failed)
    }

    private var hasFailure: Bool {
        (scope.includesChats
            && (chatPhase == .failed
                || (archivedMode
                    ? state.archivedChatListRefreshFailed : state.chatListRefreshFailed)))
            || (includesThreads
                && (threadPhase == .failed
                    || (archivedMode
                        ? state.archivedThreadListRefreshFailed : state.threadListRefreshFailed)))
    }

    private var isLoading: Bool {
        (scope.includesChats && (chatPhase == .idle || chatPhase == .loading))
            || (includesThreads && (threadPhase == .idle || threadPhase == .loading))
    }

    var isVisible: Bool {
        !isPullRefreshing && (connectionMessage != nil || isLoading || hasFailure)
    }

    var body: some View {
        if let connectionMessage, !hasInitialFailure, !isPullRefreshing {
            HStack(spacing: ChahuaTheme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text(connectionMessage)
                    .font(.caption)
                    .foregroundStyle(ChahuaTheme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
        } else if isLoading && !isPullRefreshing {
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Loading conversations")
                .listRowSeparator(.hidden)
        }
        if hasFailure && (connectionMessage == nil || hasInitialFailure)
            && !isLoading && !isPullRefreshing
        {
            Button {
                Task { await onRetry() }
            } label: {
                Label("Couldn't load conversations. Retry", systemImage: "arrow.clockwise")
            }
            .listRowSeparator(.hidden)
        }
    }
}

/// macOS List installs a hosting graph and automatic table-height machinery per
/// cell. A lazy SwiftUI scroll stack keeps the same variable-height row content
/// in one scrolling tree. iOS retains List's platform interaction and safe areas.
private struct ConversationListViewport<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(macOS)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, content: content)
            }
        #else
            List(content: content)
                .listStyle(.plain)
        #endif
    }
}
