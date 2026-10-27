import ChahuaAPI
import SwiftUI

/// The shell also observes list state. Keep its row/read/presence publications from
/// rebuilding the detail tree; the screen's scoped observers still update normally.
struct ChatDetailPresentation: View {
    private let route: Route

    init(
        chat: ChatListItem,
        currentUserID: Int32,
        store: ChatStore,
        navigationTitle: String? = nil,
        threadID: String? = nil,
        initialPosition: TimelineInitialPosition? = nil,
        onOpenThread: ((MessageResponse) -> Void)? = nil
    ) {
        route = Route(
            chat: chat, currentUserID: currentUserID, store: store,
            navigationTitle: navigationTitle, threadID: threadID,
            initialPosition: initialPosition, onOpenThread: onOpenThread,
            identity: Identity(
                storeID: ObjectIdentifier(store), accountID: store.currentUserProfile?.uid,
                currentUserID: currentUserID, sessionRevision: store.sessionRevision,
                conversation: .init(chatID: chat.id, threadID: threadID),
                initialPosition: initialPosition))
    }

    var body: some View { route.equatable() }

    private struct Identity: Hashable {
        let storeID: ObjectIdentifier
        let accountID: Int32?
        let currentUserID: Int32
        let sessionRevision: Int
        let conversation: ConversationKey
        let initialPosition: TimelineInitialPosition?

        func hash(into hasher: inout Hasher) {
            hasher.combine(storeID)
            hasher.combine(accountID)
            hasher.combine(currentUserID)
            hasher.combine(sessionRevision)
            hasher.combine(conversation)
            switch initialPosition {
            case nil:
                hasher.combine(0)
            case .liveEdge?:
                hasher.combine(1)
            case .message(let id)?:
                hasher.combine(2)
                hasher.combine(id)
            case .unread(let id)?:
                hasher.combine(3)
                hasher.combine(id)
            }
        }
    }

    private struct Route: View, Equatable {
        let chat: ChatListItem
        let currentUserID: Int32
        let store: ChatStore
        let navigationTitle: String?
        let threadID: String?
        let initialPosition: TimelineInitialPosition?
        let onOpenThread: ((MessageResponse) -> Void)?
        let identity: Identity

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identity == rhs.identity
                && lhs.navigationTitle == rhs.navigationTitle
                && lhs.chat.name == rhs.chat.name
                && lhs.chat.avatar == rhs.chat.avatar
                && lhs.chat.kind == rhs.chat.kind
                && lhs.chat.peer == rhs.chat.peer
                && lhs.chat.membershipMessagePolicy == rhs.chat.membershipMessagePolicy
                && lhs.chat.mutedUntil == rhs.chat.mutedUntil
                && lhs.chat.muteOverride == rhs.chat.muteOverride
                && lhs.chat.isMuted == rhs.chat.isMuted
                && lhs.chat.archived == rhs.chat.archived
                && (lhs.onOpenThread == nil) == (rhs.onOpenThread == nil)
        }

        var body: some View {
            ChatDetailView(
                chat: chat, currentUserID: currentUserID, store: store,
                navigationTitle: navigationTitle, threadID: threadID,
                initialPosition: initialPosition, onOpenThread: onOpenThread
            )
            // An account/reset or explicit reveal anchor owns a new timeline;
            // ordinary metadata changes preserve its viewport, composer and drafts.
            .id(identity)
        }
    }
}

// Callback contract: routes supply stable @State-backed navigation actions for a
// conversation. Captured chat presentation metadata is compared above; shell
// sign-out changes callback presence. Actions resolve current rows before routing.
// Unread counts/cursors and row previews are deliberately absent from equality:
// ChatDetailView reads the current cache when appearing/opening, and its registered
// timeline receives live read/receipt updates directly from ChatStore.
