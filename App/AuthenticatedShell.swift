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

    @State private var selectedChatID: String?

    var body: some View {
        Group {
            if usesAdaptiveSplitLayout {
                adaptiveLayout
            } else {
                phoneNavigation
            }
        }
        .onChange(of: chatStore.state.chats) { chats in
            guard chatStore.state.chatListLoadPhase == .loaded,
                  let selectedChatID,
                  !chats.contains(where: { $0.id == selectedChatID }) else { return }
            self.selectedChatID = nil
        }
    }

    private var adaptiveLayout: some View {
        ChatSplitLayout(hasSelection: selectedChatID != nil) { isSplit in
            VStack(spacing: 0) {
                ConversationListHeader { accountMenu }
                chatList(showsDisclosureIndicator: !isSplit)
            }
        } detail: { isSplit in
            detailContent
                .modifier(ChatHeaderOverlay {
                    if let chat = selectedChat {
                        ChatFloatingHeader(
                            title: chat.chatDisplayName,
                            avatarURL: chat.chatAvatarURL,
                            onBack: isSplit ? nil : { selectedChatID = nil }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, isSplit ? 0 : 12)
                        .padding(.top, isSplit ? ChatSplitMetrics.outerInset : 0)
                    }
                })
        }
    }

    private var phoneNavigation: some View {
        NavigationStack(path: phonePath) {
            chatList(showsDisclosureIndicator: true)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ConversationScopePicker()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .navigationTitle("Chats")
                .toolbar { accountToolbar }
                .navigationDestination(for: String.self) { chatID in
                    if let chat = chatStore.state.chats.first(where: { $0.id == chatID }) {
                        detailView(chat)
                    }
                }
        }
    }

    private var phonePath: Binding<[String]> {
        Binding(
            get: { selectedChatID.map { [$0] } ?? [] },
            set: { selectedChatID = $0.last }
        )
    }

    private func chatList(showsDisclosureIndicator: Bool) -> some View {
        ChatListView(
            store: chatStore,
            selectedChatID: selectedChatID,
            showsDisclosureIndicator: showsDisclosureIndicator,
            onSelectChat: { selectedChatID = $0.id }
        )
    }

    @ViewBuilder private var detailContent: some View {
        if let chat = selectedChat {
            detailView(chat)
        } else {
            ChahuaEmptyStateView(
                title: "Select a conversation",
                message: "Choose a chat from the list to start reading.",
                systemImage: "bubble.left.and.bubble.right"
            )
            .frame(maxHeight: .infinity)
        }
    }

    private func detailView(_ chat: ChatListItem) -> some View {
        ChatDetailView(chat: chat, currentUserID: me.uid, store: chatStore)
            .id(chat.id)
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
                Task { await chatStore.refreshActiveChats() }
            } label: {
                Label("Refresh chats", systemImage: "arrow.clockwise")
            }
            .disabled(chatStore.state.isRefreshingChats)
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

    private var selectedChat: ChatListItem? {
        guard let selectedChatID else { return nil }
        return chatStore.state.chats.first(where: { $0.id == selectedChatID })
    }

    private var usesAdaptiveSplitLayout: Bool {
        #if os(macOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
}
