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
            Section {
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
                            store: store, currentUserID: currentUserID, isSelected: selectedConversationID == item.id
                        )
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
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(selectedConversationID == item.id ? ChahuaTheme.ChatList.primary : Color.clear)
                    .accessibilityAddTraits(selectedConversationID == item.id ? .isSelected : [])
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            perform(.archive, on: item)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.indigo)
                        .disabled(store.pendingListActions.contains(item.id))

                        if case .chat(let chat) = item {
                            let isMuted = (chat.mutedUntil ?? .distantPast) > Date()
                            Button {
                                perform(isMuted ? .unmute : .mute, on: item)
                            } label: {
                                if isMuted {
                                    Label("Unmute", systemImage: "bell")
                                } else {
                                    Label("Mute", systemImage: "bell.slash")
                                }
                            }
                            .tint(.orange)
                            .disabled(store.pendingListActions.contains(item.id))
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if item.unreadCount > 0, item.readThroughMessageID != nil {
                            Button {
                                perform(.markRead, on: item)
                            } label: {
                                Label("Mark as Read", systemImage: "envelope.open")
                            }
                            .tint(.blue)
                            .disabled(store.pendingListActions.contains(item.id))
                        }
                    }
                }
            }
            #if os(iOS)
            .listSectionSeparator(.hidden, edges: .top)
            #endif
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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

    private var isLoaded: Bool {
        (!scope.includesChats || store.state.chatListLoadPhase == .loaded)
            && (!scope.includesThreads || store.state.threadListLoadPhase == .loaded)
    }

    private func perform(_ action: ConversationListAction, on item: ConversationListItem) {
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


