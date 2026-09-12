import ChahuaAPI
import SwiftUI

struct ThreadDetailView: View {
    let thread: ThreadListItem
    let currentUserID: Int32
    @ObservedObject var store: ChatStore
    @State private var chat: ChatListItem?
    @State private var failed = false

    var body: some View {
        Group {
            if let chat {
                ChatDetailView(
                    chat: chat, currentUserID: currentUserID, store: store,
                    navigationTitle: threadTitle,
                    threadID: thread.threadRootMessage.id,
                    initialPosition: thread.unreadCount > 0
                        ? .unread(after: thread.lastReadMessageId)
                        : .liveEdge)
            } else if failed {
                ChahuaRecoverableErrorView(
                    title: "Couldn’t open thread", message: "Check your connection and try again.",
                    retryTitle: "Try again", onRetry: { Task { await loadChat() } })
            } else {
                ChahuaLoadingView(title: "Loading thread")
            }
        }
        .task(id: thread.chatId) { await loadChat() }
    }

    private var threadTitle: String {
        let title = messagePreview(thread.threadRootMessage)
        return title.isEmpty ? String(localized: "Message") : title
    }

    private func loadChat() async {
        failed = false
        do {
            let chat = try await store.chatForThread(thread)
            try Task.checkCancellation()
            self.chat = chat
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}
