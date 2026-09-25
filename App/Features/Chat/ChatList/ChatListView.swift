import ChahuaAPI
import SwiftUI

struct ChatListView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var drafts: ChatDraftStore
    let currentUserID: Int32
    let scope: ConversationListScope
    var archivedMode = false
    var showThreadsInMessages = ConversationListPreferences.defaultShowThreadsInMessages
    var onOpenArchived: (() -> Void)?
    var badgeColor = ConversationListPreferences.defaultUnreadBadgeColor
    let selectedConversationID: ConversationKey?
    let onSelectConversation: (ConversationListItem) -> Void
    @State private var isPullRefreshing = false
    @State private var revealedConversationID: ConversationKey?
    #if os(macOS)
        @StateObject private var overlayScrollers = ChatListOverlayScrollerScope()
    #endif

    private struct LoadID: Equatable {
        let scope: ConversationListScope
        let archived: Bool
        let showThreadsInMessages: Bool
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
        let items = ConversationListItem.entries(
            chats: archivedMode ? store.state.archivedChats : store.state.chats,
            threads: archivedMode ? store.state.archivedThreads : store.state.threads,
            scope: scope, archived: archivedMode, showThreadsInMessages: showThreadsInMessages,
            draftUpdatedAt: drafts.draftUpdatedAt)
        List {
            ConversationListLoadStatus(
                state: store.state, scope: scope, archivedMode: archivedMode,
                showThreadsInMessages: showThreadsInMessages,
                isPullRefreshing: isPullRefreshing, onRetry: { await refreshScope() }
            )
            #if os(macOS)
                .background(ChatListOverlayScrollerMarker(scope: overlayScrollers))
            #endif
            if !archivedMode, let onOpenArchived, hasArchivedConversations {
                Button(action: onOpenArchived) { archivedEntry }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("archived-conversations")
                    #if os(macOS)
                        .background(ChatListOverlayScrollerMarker(scope: overlayScrollers))
                        .listRowInsets(EdgeInsets())
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
                #if os(macOS)
                    .background(ChatListOverlayScrollerMarker(scope: overlayScrollers))
                #endif
            }
            ForEach(items) { item in
                swipeRow(for: item)
                    #if os(macOS)
                        .background(ChatListOverlayScrollerMarker(scope: overlayScrollers))
                    #endif
                    #if os(iOS)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    #else
                        .listRowInsets(EdgeInsets())
                    #endif
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            #if os(iOS)
                .listSectionSeparator(.hidden, edges: .top)
            #endif
        }
        .listStyle(.plain)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        #if os(macOS)
            .background(
                ChatListOverlayScrollerMarker(scope: overlayScrollers, keepsScopeAlive: true))
        #endif
        .onChange(of: scope) { _, _ in revealedConversationID = nil }
        .onChange(of: archivedMode) { _, _ in revealedConversationID = nil }
        .onChange(of: selectedConversationID) { _, _ in revealedConversationID = nil }
        .onDisappear { revealedConversationID = nil }
        .task(
            id: LoadID(
                scope: scope, archived: archivedMode, showThreadsInMessages: showThreadsInMessages
            )
        ) { await loadScope() }
        .refreshable {
            isPullRefreshing = true
            defer { isPullRefreshing = false }
            await refreshScope()
        }
        .alert(
            "Conversation actions",
            isPresented: Binding(
                get: { store.listActionError != nil },
                set: { if !$0 { store.listActionError = nil } })
        ) {
            Button("OK") { store.listActionError = nil }
        } message: {
            Text(store.listActionError ?? "")
        }
    }

    private var archivedEntry: some View {
        let count = ConversationTabBadges(
            chats: store.state.archivedChats, threads: store.state.archivedThreads,
            archived: true, showThreadsInMessages: showThreadsInMessages)[scope]
        return HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(
                    width: ConversationListRow.avatarDiameter,
                    height: ConversationListRow.avatarDiameter
                )
                .background(ChahuaTheme.ChatList.primary, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Archived").font(.headline)
                Text("View archived chats and threads")
                    .modifier(ConversationListSubtitleStyle(isSelected: false))
            }
            Spacer(minLength: 8)
            if count > 0 {
                Text(count > 999 ? "999+" : String(count))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(count) unread conversations")
            }
        }
        .padding(.horizontal, ChatSplitMetrics.outerInset)
        .frame(height: 68)
        .contentShape(Rectangle())
    }

    private func selectionButton(for item: ConversationListItem) -> some View {
        Button {
            // A tap dismisses any open controls before it can navigate.
            guard revealedConversationID == nil else {
                revealedConversationID = nil
                return
            }
            guard selectedConversationID != item.id else { return }
            onSelectConversation(item)
        } label: {
            ConversationListRow(
                item: item,
                draft: drafts.draftText(chatID: item.id.chatID, threadID: item.id.threadID),
                store: store, currentUserID: currentUserID,
                isSelected: selectedConversationID == item.id, badgeColor: badgeColor
            )
            .contentShape(Rectangle())
            .overlay {
                if isBlockingListAction(for: item) {
                    ProgressView()
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Updating conversation")
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedConversationID == item.id ? .isSelected : [])
    }

    private func swipeRow(for item: ConversationListItem) -> some View {
        let leading = leadingSwipeAction(for: item)
        let trailing = trailingSwipeActions(for: item)
        let isBusy = store.pendingListAction(for: item.id) != nil
        let blocksInteraction = isBlockingListAction(for: item)
        return SwipeRow(
            id: item.id, revealedID: $revealedConversationID,
            leadingAction: leading, trailingActions: trailing, isBusy: blocksInteraction,
            onAction: { performSwipeAction($0, on: item) }
        ) {
            selectionButton(for: item)
                .background(
                    selectedConversationID == item.id ? ChahuaTheme.ChatList.primary : Color.clear
                )
                .accessibilityActions {
                    if !isBusy {
                        if let leading {
                            Button(leading.title) { performSwipeAction(leading.action, on: item) }
                        }
                        ForEach(trailing, id: \.symbol) { action in
                            Button(action.title) { performSwipeAction(action.action, on: item) }
                        }
                    }
                }
        }
        .onChange(of: blocksInteraction) { _, blocksInteraction in
            if blocksInteraction, revealedConversationID == item.id { revealedConversationID = nil }
        }
        .onDisappear {
            if revealedConversationID == item.id { revealedConversationID = nil }
        }
    }

    private func isBlockingListAction(for item: ConversationListItem) -> Bool {
        guard let action = store.pendingListAction(for: item.id) else { return false }
        return action != .markRead && action != .markUnread
    }

    private func leadingSwipeAction(for item: ConversationListItem) -> SwipeRowAction? {
        guard item.readThroughMessageID != nil else { return nil }
        if item.unreadCount > 0 {
            return .init(
                action: ConversationListAction.markRead.rawValue,
                title: AppLanguage.localized("Mark as Read"), symbol: "checkmark.message",
                tint: .blue)
        }
        if case .chat = item {
            return .init(
                action: ConversationListAction.markUnread.rawValue,
                title: AppLanguage.localized("Mark as Unread"), symbol: "message.badge", tint: .blue
            )
        }
        // Threads have no mark-unread endpoint; do not offer a local-only badge.
        return nil
    }

    private func trailingSwipeActions(for item: ConversationListItem) -> [SwipeRowAction] {
        let archive = SwipeRowAction(
            action: (archivedMode ? ConversationListAction.unarchive : .archive).rawValue,
            title: archivedMode
                ? AppLanguage.localized("Unarchive") : AppLanguage.localized("Archive"),
            symbol: archivedMode ? "tray" : "archivebox", tint: .indigo)
        guard case .chat(let chat) = item else { return [archive] }
        let isMuted = (chat.mutedUntil ?? .distantPast) > Date()
        return [
            archive,
            .init(
                action: (isMuted ? ConversationListAction.unmute : .mute).rawValue,
                title: isMuted ? AppLanguage.localized("Unmute") : AppLanguage.localized("Mute"),
                symbol: isMuted ? "bell" : "bell.slash", tint: .orange),
        ]
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
        Task { await store.performListAction(action, conversation: item.id) }
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

    var body: some View {
        if isLoading && !isPullRefreshing {
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Loading conversations")
                .listRowSeparator(.hidden)
        }
        if hasFailure && !isLoading && !isPullRefreshing {
            Button {
                Task { await onRetry() }
            } label: {
                Label("Couldn't load conversations. Retry", systemImage: "arrow.clockwise")
            }
            .listRowSeparator(.hidden)
        }
    }
}
