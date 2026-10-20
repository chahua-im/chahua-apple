import ChahuaAPI
import SwiftUI

/// Uses the same composite drawing as thread rows, including roots outside subscriptions.
struct ThreadHeaderAvatar: View {
    let key: ConversationKey
    let parent: ChatListItem?
    @ObservedObject var store: ChatStore
    let currentUserID: Int32
    var diameter: CGFloat = 38
    var root: MessageResponse? = nil
    @State private var resolvedParent: ChatListItem?
    @State private var resolvedRoot: MessageResponse?
    @State private var resolvedKey: ConversationKey?

    private var listedThread: ThreadListItem? {
        store.state.threads.first {
            $0.chatId == key.chatID && $0.threadRootMessage.id.description == key.threadID
        }
            ?? store.state.archivedThreads.first {
                $0.chatId == key.chatID && $0.threadRootMessage.id.description == key.threadID
            }
    }

    private var knownParent: ChatListItem? {
        store.state.chats.first { $0.id == key.chatID }
            ?? store.state.archivedChats.first { $0.id == key.chatID }
            ?? (parent?.id == key.chatID ? parent : nil)
            ?? (resolvedKey == key ? resolvedParent : nil)
    }

    private var knownRoot: MessageResponse? {
        if let root, root.chatId == key.chatID, root.id.description == key.threadID,
            root.replyRootId == nil
        {
            return root
        }
        return resolvedKey == key ? resolvedRoot : nil
    }

    var body: some View {
        let thread = listedThread
        let chat = knownParent
        ThreadAvatarView(
            chatName: chat?.chatDisplayName ?? thread?.chatName ?? AppLanguage.localized("Thread"),
            chatAvatar: chat?.chatAvatarURL?.absoluteString ?? thread?.chatAvatar,
            parent: chat, participants: thread?.participants ?? [],
            rootSender: thread?.threadRootMessage.sender ?? knownRoot?.sender,
            currentUserID: currentUserID, diameter: diameter
        )
        .task(id: key) {
            // A changed route must never display the previous route's resolved author or kind.
            let requestKey = key
            resolvedParent = nil
            resolvedRoot = nil
            resolvedKey = requestKey
            do {
                if knownParent == nil {
                    let info = try await store.groupInfo(chatID: requestKey.chatID)
                    try Task.checkCancellation()
                    guard key == requestKey else { return }
                    resolvedParent = ChatListItem(
                        id: info.id, name: info.name, avatar: info.avatar,
                        unreadCount: 0, archived: false, kind: info.kind, peer: info.peer)
                }
                // DM badges need only the peer; listed and timeline-opened roots need no HTTP.
                if knownParent?.kind != .dm, listedThread == nil, knownRoot == nil {
                    let message = try await store.threadRoot(for: requestKey)
                    try Task.checkCancellation()
                    guard key == requestKey else { return }
                    resolvedRoot = message
                }
            } catch {
                // Keep available identity metadata; cancellation and session changes publish nothing.
            }
        }
    }
}
