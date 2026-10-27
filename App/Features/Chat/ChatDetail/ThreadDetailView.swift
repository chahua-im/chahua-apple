import ChahuaAPI
import SwiftUI

struct ThreadDetailView: View {
    let thread: ThreadListItem
    let currentUserID: Int32
    // Loading/routing uses the store imperatively; ChatDetailPresentation owns
    // the conversation's reactive dependencies, not unrelated list changes.
    let store: ChatStore
    @State private var chat: ChatListItem?
    @State private var failed = false

    var body: some View {
        Group {
            if let chat {
                ChatDetailPresentation(
                    chat: chat, currentUserID: currentUserID, store: store,
                    navigationTitle: threadTitle,
                    threadID: thread.threadRootMessage.id.description)
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
        return title.isEmpty ? AppLanguage.localized("Message") : title
    }

    private func loadChat() async {
        failed = false
        let accountID = store.currentUserProfile?.uid
        let sessionRevision = store.sessionRevision
        do {
            let chat = try await store.chatForThread(thread)
            try Task.checkCancellation()
            guard store.currentUserProfile?.uid == accountID,
                store.sessionRevision == sessionRevision
            else { return }
            self.chat = chat
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, store.currentUserProfile?.uid == accountID,
                store.sessionRevision == sessionRevision
            else { return }
            failed = true
        }
    }
}
