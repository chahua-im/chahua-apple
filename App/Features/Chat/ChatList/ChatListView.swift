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

    var body: some View {
        let items = ConversationListItem.entries(
            chats: store.state.chats, threads: store.state.threads,
            scope: scope, draftUpdatedAt: drafts.draftUpdatedAt)
        List {
            ConversationListLoadStatus(
                state: store.state, scope: scope, isPullRefreshing: isPullRefreshing)
            if items.isEmpty && isLoaded {
                ChahuaEmptyStateView(
                    title: "No conversations",
                    message: "Conversations in this category will appear here.",
                    systemImage: scope == .threads ? "text.bubble" : "bubble.left.and.bubble.right")
            }
            ForEach(items) { item in
                Button {
                    guard selectedConversationID != item.id else { return }
                    onSelectConversation(item)
                } label: {
                    ConversationListRow(
                        item: item, draft: drafts.draftText(chatID: item.id.chatID, threadID: item.id.threadID),
                        store: store, currentUserID: currentUserID, isSelected: selectedConversationID == item.id)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(selectedConversationID == item.id ? ChahuaTheme.ChatList.primary : Color.clear)
                .accessibilityAddTraits(selectedConversationID == item.id ? .isSelected : [])
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task(id: scope) { await loadScope() }
        .refreshable {
            isPullRefreshing = true
            defer { isPullRefreshing = false }
            await refreshScope()
        }
    }

    private var isLoaded: Bool {
        (!scope.includesChats || store.state.chatListLoadPhase == .loaded)
            && (!scope.includesThreads || store.state.threadListLoadPhase == .loaded)
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


