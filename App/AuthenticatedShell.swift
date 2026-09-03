import ChahuaAPI
import SwiftUI

/// Authenticated navigation boundary.
///
/// This view owns the navigation stack for every signed-in destination. Feature
/// stores own server data; future route state belongs here rather than in them.
struct AuthenticatedShell: View {
    @ObservedObject var chatStore: ChatStore
    let me: MeResponse
    let isSigningOut: Bool
    let onSignOut: () -> Void

    var body: some View {
        NavigationStack {
            ChatListView(store: chatStore)
                .navigationTitle("Chats")
                .navigationDestination(for: ChatListItem.self) { chat in
                    ChatDetailView(chat: chat)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Account") {
                            Text(me.username)
                            Button("Sign out", role: .destructive, action: onSignOut)
                                .disabled(isSigningOut)
                        }
                    }
                }
        }
    }
}
