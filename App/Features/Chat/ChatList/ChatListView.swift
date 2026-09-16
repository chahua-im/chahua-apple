import ChahuaAPI
import SwiftUI

struct ChatListView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var drafts: ChatDraftStore
    let currentUserID: Int32
    let scope: ConversationListScope
    let selectedConversationID: ConversationKey?
    let onSelectConversation: (ConversationListItem) -> Void
    @State private var isPullRefreshing = false
    @State private var revealedConversationID: ConversationKey?
    #if os(macOS)
    @StateObject private var overlayScrollers = ChatListOverlayScrollerScope()
    #endif

    var body: some View {
        let items = ConversationListItem.entries(
            chats: store.state.chats, threads: store.state.threads,
            scope: scope, draftUpdatedAt: drafts.draftUpdatedAt)
        List {
            ConversationListLoadStatus(
                state: store.state, scope: scope, isPullRefreshing: isPullRefreshing)
                #if os(macOS)
                .background(ChatListOverlayScrollerMarker(scope: overlayScrollers))
                #endif
            if items.isEmpty && isLoaded {
                ChahuaEmptyStateView(
                    title: "No conversations",
                    message: "Conversations in this category will appear here.",
                    systemImage: scope == .threads ? "text.bubble" : "bubble.left.and.bubble.right")
                    #if os(macOS)
                    .background(ChatListOverlayScrollerMarker(scope: overlayScrollers))
                    #endif
            }
            ForEach(items) { item in
                swipeRow(for: item)
                    #if os(macOS)
                    .background(ChatListOverlayScrollerMarker(scope: overlayScrollers))
                    #endif
                    .listRowInsets(EdgeInsets())
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
        .background(ChatListOverlayScrollerMarker(scope: overlayScrollers, keepsScopeAlive: true))
        #endif
        .onChange(of: scope) { _, _ in revealedConversationID = nil }
        .onChange(of: selectedConversationID) { _, _ in revealedConversationID = nil }
        .onDisappear { revealedConversationID = nil }
        .task(id: scope) { await loadScope() }
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
                item: item, draft: drafts.draftText(chatID: item.id.chatID, threadID: item.id.threadID),
                store: store, currentUserID: currentUserID, isSelected: selectedConversationID == item.id)
                .contentShape(Rectangle())
                .overlay {
                    if store.pendingListActions.contains(item.id) {
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
        let isBusy = store.pendingListActions.contains(item.id)
        return SwipeRow(
            id: item.id, revealedID: $revealedConversationID,
            leadingAction: leading, trailingActions: trailing, isBusy: isBusy,
            onAction: { performSwipeAction($0, on: item) }
        ) {
            selectionButton(for: item)
                .background(selectedConversationID == item.id ? ChahuaTheme.ChatList.primary : Color.clear)
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
        .onChange(of: isBusy) { _, busy in
            if busy, revealedConversationID == item.id { revealedConversationID = nil }
        }
        .onDisappear {
            if revealedConversationID == item.id { revealedConversationID = nil }
        }
    }

    private func leadingSwipeAction(for item: ConversationListItem) -> SwipeRowAction? {
        guard item.readThroughMessageID != nil else { return nil }
        if item.unreadCount > 0 {
            return .init(action: ConversationListAction.markRead.rawValue, title: String(localized: "Mark as Read"), symbol: "checkmark.message", tint: .blue)
        }
        if case .chat = item {
            return .init(action: ConversationListAction.markUnread.rawValue, title: String(localized: "Mark as Unread"), symbol: "message.badge", tint: .blue)
        }
        // Threads have no mark-unread endpoint; do not offer a local-only badge.
        return nil
    }

    private func trailingSwipeActions(for item: ConversationListItem) -> [SwipeRowAction] {
        let archive = SwipeRowAction(action: ConversationListAction.archive.rawValue, title: String(localized: "Archive"), symbol: "archivebox", tint: .indigo)
        guard case .chat(let chat) = item else { return [archive] }
        let isMuted = (chat.mutedUntil ?? .distantPast) > Date()
        return [
            archive,
            .init(
                action: (isMuted ? ConversationListAction.unmute : .mute).rawValue,
                title: isMuted ? String(localized: "Unmute") : String(localized: "Mute"),
                symbol: isMuted ? "bell" : "bell.slash", tint: .orange),
        ]
    }

    private func performSwipeAction(_ action: String, on item: ConversationListItem) {
        guard let action = ConversationListAction(rawValue: action) else { return }
        perform(action, on: item)
    }

    private var isLoaded: Bool {
        (!scope.includesChats || store.state.chatListLoadPhase == .loaded)
            && (!scope.includesThreads || store.state.threadListLoadPhase == .loaded)
    }

    private func perform(_ action: ConversationListAction, on item: ConversationListItem) {
        guard !store.pendingListActions.contains(item.id) else { return }
        revealedConversationID = nil
        Task { await store.performListAction(action, conversation: item.id) }
    }


    private func loadScope() async {
        async let chats: Void = loadChatsIfNeeded()
        async let threads: Void = loadThreadsIfNeeded()
        _ = await (chats, threads)
    }

    private func loadChatsIfNeeded() async {
        if scope.includesChats { await store.loadActiveChats() }
    }

    private func loadThreadsIfNeeded() async {
        if scope.includesThreads { await store.loadActiveThreads() }
    }

    private func refreshScope() async {
        if scope == .messages { await store.refreshActiveConversations() }
        else if scope == .threads { await store.refreshActiveThreads() }
        else { await store.refreshActiveChats() }
    }
}

/// The selected scope has one presentation state even when multiple lists load independently.
struct ConversationListLoadStatus: View {
    let state: ChatState
    let scope: ConversationListScope
    var isPullRefreshing = false

    private var isLoading: Bool {
        (scope.includesChats && (state.chatListLoadPhase == .idle || state.chatListLoadPhase == .loading))
            || (scope.includesThreads && (state.threadListLoadPhase == .idle || state.threadListLoadPhase == .loading))
    }

    var body: some View {
        if isLoading && !isPullRefreshing {
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Loading conversations")
                .listRowSeparator(.hidden)
        }
    }
}


