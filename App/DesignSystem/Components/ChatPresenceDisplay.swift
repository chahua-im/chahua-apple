import ChahuaAPI
import Foundation
import SwiftUI

/// Absolute server snapshots are the only source of status; missing presence stays unknown.
enum ChatPresenceDisplay {
    static func scope(for chat: ChatListItem?) -> PresenceScope {
        guard let chat else { return PresenceScope() }
        switch chat.kind {
        case .dm:
            return PresenceScope(userIDs: chat.peer.map { [$0.uid] } ?? [])
        case .group:
            return PresenceScope(chatIDs: [chat.id])
        }
    }

    static func isOnline(_ chat: ChatListItem, in state: ChatState) -> Bool {
        guard chat.kind == .dm, let uid = chat.peer?.uid else { return false }
        return state.userPresence[uid]?.online == true
    }

    static func subtitle(for chat: ChatListItem?, in state: ChatState, now: Date = Date())
        -> String?
    {
        guard let chat else { return nil }
        switch chat.kind {
        case .dm:
            guard let uid = chat.peer?.uid, let presence = state.userPresence[uid] else {
                return nil
            }
            return UserPresenceDisplay.subtitle(presence, now: now)
        case .group:
            guard let presence = state.groupPresence[chat.id] else { return nil }
            return AppLanguage.localized(
                "\(Int(presence.onlineCount)) online · \(Int(presence.memberCount)) members")
        }
    }

}

private struct PresenceScopeModifier: ViewModifier {
    let scope: PresenceScope
    let store: ChatStore
    @State private var id = UUID()
    @State private var isMounted = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isMounted = true
                store.setPresenceScope(scope, for: id)
            }
            .onChange(of: scope) { _, scope in
                guard isMounted else { return }
                store.setPresenceScope(scope, for: id)
            }
            .onDisappear {
                isMounted = false
                store.removePresenceScope(for: id)
            }
    }
}

extension View {
    /// Each mounted consumer owns a stable scope; the store deduplicates and caps the union.
    func presenceScope(_ scope: PresenceScope, store: ChatStore) -> some View {
        modifier(PresenceScopeModifier(scope: scope, store: store))
    }
}
