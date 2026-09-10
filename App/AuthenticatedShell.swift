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
    let me: MeResponse
    let isSigningOut: Bool
    let onSignOut: () -> Void

    @State private var selectedScope: ConversationListScope = .messages
    @State private var selectedConversationID: ConversationKey?

    var body: some View {
        Group {
            if usesAdaptiveSplitLayout {
                adaptiveLayout
            } else {
                phoneNavigation
            }
        }
        .onChange(of: chatStore.state) { state in
            guard let selectedConversationID else { return }
            let loaded = selectedConversationID.threadID == nil
                ? state.chatListLoadPhase == .loaded : state.threadListLoadPhase == .loaded
            if loaded && selectedConversation == nil { self.selectedConversationID = nil }
        }
    }

    private var adaptiveLayout: some View {
        ChatSplitLayout(hasSelection: selectedConversationID != nil) { _ in
            VStack(spacing: 0) {
                ConversationListHeader(selection: $selectedScope) { accountMenu }
                chatList()
            }
        } detail: { isSplit in
            detailContent
                .modifier(ChatHeaderOverlay {
                    if let conversation = selectedConversation {
                        ChatFloatingHeader(
                            title: conversation.title,
                            onBack: isSplit ? nil : { selectedConversationID = nil }
                        ) {
                            ConversationAvatarView(
                                item: conversation, store: chatStore, currentUserID: me.uid, diameter: 32)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, isSplit ? 0 : 12)
                        .padding(.top, isSplit ? ChatSplitMetrics.outerInset : 0)
                    }
                })
        }
    }

    private var phoneNavigation: some View {
        NavigationStack(path: phonePath) {
            chatList()
                .safeAreaInset(edge: .top, spacing: 0) {
                    ConversationScopePicker(selection: $selectedScope)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .navigationTitle("Chats")
                .toolbar { accountToolbar }
                .navigationDestination(for: ConversationKey.self) { _ in
                    detailContent
                }
        }
    }

    private var phonePath: Binding<[ConversationKey]> {
        Binding(
            get: { selectedConversationID.map { [$0] } ?? [] },
            set: { selectedConversationID = $0.last }
        )
    }

    private func chatList() -> some View {
        ChatListView(
            store: chatStore,
            drafts: chatStore.drafts,
            currentUserID: me.uid,
            scope: selectedScope,
            selectedConversationID: selectedConversationID,
            onSelectConversation: { selectedConversationID = $0.id }
        )
    }

    @ViewBuilder private var detailContent: some View {
        if let conversation = selectedConversation {
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
            ChatDetailView(chat: chat, currentUserID: me.uid, store: chatStore)
                .id(conversation.id)
        case .thread(let thread):
            ThreadDetailView(thread: thread, currentUserID: me.uid, store: chatStore)
                .id(conversation.id)
        }
    }

    @ToolbarContentBuilder private var accountToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            accountMenu
        }
    }

    private var accountMenu: some View {
        Menu {
            Text(me.username)
            Button {
                Task { await chatStore.refreshActiveConversations() }
            } label: {
                Label("Refresh chats", systemImage: "arrow.clockwise")
            }
            .disabled(chatStore.state.isRefreshingChats || chatStore.state.isRefreshingThreads)
            Button("Sign out", role: .destructive, action: onSignOut)
                .disabled(isSigningOut)
        } label: {
            if usesAdaptiveSplitLayout {
                AvatarView(url: me.avatarUrl.flatMap(URL.init(string:)), displayName: me.username, diameter: 26)
                    .accessibilityLabel("Account")
            } else {
                Label("Account", systemImage: "person.crop.circle")
            }
        }
    }

    private var selectedConversation: ConversationListItem? {
        guard let selectedConversationID else { return nil }
        if let threadID = selectedConversationID.threadID {
            return chatStore.state.threads.first {
                $0.chatId == selectedConversationID.chatID && $0.threadRootMessage.id == threadID
            }.map(ConversationListItem.thread)
        }
        return chatStore.state.chats.first { $0.id == selectedConversationID.chatID }.map(ConversationListItem.chat)
    }

    private var usesAdaptiveSplitLayout: Bool {
        #if os(macOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
}
