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
            chatList()
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
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .navigationDestination(for: ConversationKey.self) { _ in
                    detailContent
                        #if os(iOS)
                        .modifier(ChatPhoneDetailHeader(title: selectedConversation?.title ?? "") {
                            if let conversation = selectedConversation {
                                ConversationAvatarView(
                                    item: conversation, store: chatStore, currentUserID: me.uid, diameter: 32)
                            }
                        })
                        #endif
                }
        }
    }

    private var phonePath: Binding<[ConversationKey]> {
        Binding(
            get: { selectedConversationID.map { [$0] } ?? [] },
            set: { selectedConversationID = $0.last }
        )
    }

    @ViewBuilder private func chatList() -> some View {
        let list = ChatListView(
            store: chatStore,
            drafts: chatStore.drafts,
            currentUserID: me.uid,
            scope: selectedScope,
            selectedConversationID: selectedConversationID,
            onSelectConversation: { selectedConversationID = $0.id }
        )
        #if os(iOS)
        if #available(iOS 26, *) {
            list
                .safeAreaBar(edge: .top, spacing: 0) {
                    ConversationListHeader(selection: $selectedScope) { accountMenu }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            list.safeAreaInset(edge: .top, spacing: 0) {
                ConversationListHeader(selection: $selectedScope) { accountMenu }
                    .background(.regularMaterial)
            }
        }
        #else
        VStack(spacing: 0) {
            ConversationListHeader(selection: $selectedScope) { accountMenu }
            list
        }
        #endif
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
            AvatarView(
                url: me.avatarUrl.flatMap(URL.init(string:)),
                displayName: me.username,
                diameter: accountAvatarDiameter
            )
            .accessibilityLabel("Account")
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
