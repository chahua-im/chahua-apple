import ChahuaAPI
import Combine
import SwiftUI

struct ThreadDetailView: View {
    let thread: ThreadListItem
    let currentUserID: Int32
    let store: ChatStore
    @State private var parentInfo: (scope: ParentScope, info: GroupInfoResponse)?
    @State private var revokedParent: ParentScope?

    private struct ParentScope: Equatable {
        let chatID: String
        let accountID: Int32
        let sessionRevision: Int
    }

    var body: some View {
        let scope = parentScope
        Group {
            if canPresentParent(scope) {
                ChatDetailPresentation(
                    chat: parentChat(for: scope), currentUserID: currentUserID, store: store,
                    navigationTitle: threadTitle,
                    threadID: thread.threadRootMessage.id.description)
            } else {
                ChahuaEmptyStateView(
                    title: "Couldn’t open thread", message: "This thread is no longer available.",
                    systemImage: "bubble.left.and.bubble.right")
            }
        }
        // The detail's session-scoped, connectivity-keyed task refreshes this metadata
        // independently of the timeline. Avoid a second groupInfo request racing it.
        .onReceive(store.$groupInfoByChatID.map { $0[scope.chatID] }.removeDuplicates()) { info in
            guard scope == parentScope, canPresentParent(scope),
                parentInfo?.scope != scope || parentInfo?.info != info
            else { return }
            parentInfo = info.map { (scope, $0) }
        }
        .onReceive(store.chatAccessInvalidations) { chatID in
            guard chatID == scope.chatID, scope == parentScope else { return }
            revokedParent = scope
            parentInfo = nil
        }
    }

    private var threadTitle: String {
        let title = messagePreview(thread.threadRootMessage)
        return title.isEmpty ? AppLanguage.localized("Message") : title
    }

    private var parentScope: ParentScope {
        ParentScope(
            chatID: thread.chatId, accountID: currentUserID, sessionRevision: store.sessionRevision)
    }

    private func canPresentParent(_ scope: ParentScope) -> Bool {
        store.currentUserProfile?.uid == scope.accountID && revokedParent != scope
            && store.canPresentThreadParent(chatID: scope.chatID)
    }

    private func parentChat(for scope: ParentScope) -> ChatListItem {
        let listed = store.chat(id: scope.chatID)
        let info =
            (parentInfo?.scope == scope ? parentInfo?.info : nil)
            ?? store.groupInfoByChatID[scope.chatID]
        if let info {
            return ChatListItem(
                id: info.id, name: info.name, avatar: info.avatar, unreadCount: 0,
                mutedUntil: info.mutedUntil, muteOverride: info.muteOverride, isMuted: info.isMuted,
                archived: listed?.archived ?? thread.archived, kind: info.kind, peer: info.peer,
                membershipMessagePolicy: info.membershipMessagePolicy)
        }
        // A list row supplies presentation, not access or send permission.
        return listed
            ?? ChatListItem(
                id: thread.chatId, name: thread.chatName, avatar: thread.chatAvatar,
                unreadCount: 0, archived: thread.archived, kind: thread.chatKind, peer: thread.peer)
    }
}
