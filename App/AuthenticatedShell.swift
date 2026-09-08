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
            NavigationStack {
                chatList(showsDisclosureIndicator: !isSplit)
                    .navigationTitle("Chats")
                    .toolbar { accountToolbar }
            }
        } detail: { isSplit in
            NavigationStack {
                detailContent
                    .toolbar {
                        if !isSplit {
                            ToolbarItem(placement: .navigation) {
                                Button {
                                    selectedChatID = nil
                                } label: {
                                    Label("Chats", systemImage: "chevron.backward")
                                }
                            }
                        }
                    }
            }
        }
    }

    private var phoneNavigation: some View {
        NavigationStack(path: phonePath) {
            chatList(showsDisclosureIndicator: true)
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
            Menu("Account") {
                Text(me.username)
                Button("Sign out", role: .destructive, action: onSignOut)
                    .disabled(isSigningOut)
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
