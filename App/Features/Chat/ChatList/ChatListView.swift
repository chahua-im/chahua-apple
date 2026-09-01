import ChahuaAPI
import SwiftUI

struct ChatListView: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        content
            .task { await store.loadActiveChats() }
    }

    @ViewBuilder private var content: some View {
        switch store.state.chatListLoadPhase {
        case .idle, .loading:
            ChahuaLoadingView(title: "Loading chats")
        case .failed:
            ChahuaRecoverableErrorView(
                title: "Couldn’t load chats",
                message: "Check your connection and try again.",
                retryTitle: "Try again",
                onRetry: { Task { await store.loadActiveChats() } }
            )
        case .loaded where store.state.chats.isEmpty:
            ChahuaEmptyStateView(
                title: "No active chats",
                message: "Active chats will appear here.",
                systemImage: "bubble.left.and.bubble.right"
            )
        case .loaded:
            List(store.state.chats) { chat in
                ChatListRow(chat: chat)
            }
        }
    }
}

private struct ChatListRow: View {
    let chat: ChatListItem

    var body: some View {
        ChahuaListRow {
            AvatarView(url: avatarURL, displayName: displayName)
        } content: {
            Text(displayName)
                .font(.headline)
                .lineLimit(1)
        } trailing: {
            EmptyView()
        }
    }

    private var displayName: String {
        switch chat.kind {
        case .dm:
            return nonEmpty(chat.peer?.username) ?? nonEmpty(chat.name) ?? String(localized: "Direct Message \(chat.id)")
        case .group:
            return nonEmpty(chat.name) ?? String(localized: "Chat \(chat.id)")
        }
    }

    private var avatarURL: URL? {
        let value: String?
        switch chat.kind {
        case .dm:
            value = chat.peer?.avatarUrl ?? chat.avatar
        case .group:
            value = chat.avatar
        }
        return value.flatMap(URL.init(string:))
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
