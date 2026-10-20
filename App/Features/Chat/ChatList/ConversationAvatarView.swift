import ChahuaAPI
import SwiftUI

struct ConversationAvatarView: View {
    let item: ConversationListItem
    @ObservedObject var store: ChatStore
    let currentUserID: Int32
    var diameter: CGFloat = 40
    var isSelected = false
    @State private var resolvedParent: ChatListItem?

    var body: some View {
        Group {
            switch item {
            case .chat(let chat):
                AvatarView(
                    url: chat.chatAvatarURL, displayName: chat.chatDisplayName, diameter: diameter,
                    isOnline: ChatPresenceDisplay.isOnline(chat, in: store.state)
                )
                .presenceScope(
                    chat.kind == .dm ? ChatPresenceDisplay.scope(for: chat) : PresenceScope(),
                    store: store)
            case .thread(let thread):
                ThreadAvatarView(
                    chatName: thread.chatName, chatAvatar: thread.chatAvatar,
                    parent: store.state.chats.first(where: { $0.id == thread.chatId })
                        ?? store.state.archivedChats.first(where: { $0.id == thread.chatId })
                        ?? resolvedParent,
                    participants: thread.participants, rootSender: thread.threadRootMessage.sender,
                    currentUserID: currentUserID, diameter: diameter, isSelected: isSelected)
            }
        }
        .task(id: item.id.chatID) {
            resolvedParent = nil
            guard case .thread(let thread) = item,
                !store.state.chats.contains(where: { $0.id == thread.chatId })
            else { return }
            // Archived parents can be absent from the active list. Resolve their kind
            // rather than guessing that every subscribed thread belongs to a group.
            do {
                let parent = try await store.chatForThread(thread)
                try Task.checkCancellation()
                resolvedParent = parent
            } catch {
                // HTTP failures are logged by the client; retain the available avatar fallback.
            }
        }
    }
}

struct ThreadAvatarView: View {
    let chatName: String
    let chatAvatar: String?
    let parent: ChatListItem?
    let participants: [User]
    let rootSender: User?
    let currentUserID: Int32
    var diameter: CGFloat = 48
    var isSelected = false
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var isDM: Bool { parent?.kind == .dm }
    private var participant: User? { participants.first { $0.uid != currentUserID } }
    private var primaryName: String {
        if isDM {
            if let peer = parent?.peer { return peer.username ?? chatName }
            return participant?.name ?? chatName
        }
        return chatName
    }
    private var primaryURL: URL? {
        let value =
            isDM
            ? ((parent?.peer != nil ? parent?.peer?.avatarUrl : participant?.avatarUrl)
                ?? chatAvatar)
            : chatAvatar
        return value.flatMap(URL.init(string:))
    }

    var body: some View {
        let secondarySize = max(16, (diameter * 0.55).rounded())
        AvatarView(url: primaryURL, displayName: primaryName, diameter: diameter)
            .overlay(alignment: .topTrailing) {
                // Do not infer group-vs-DM styling while the parent kind is unresolved.
                if isDM || (parent != nil && !(rootSender?.name ?? "").isEmpty) {
                    Group {
                        if isDM {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(
                                    width: secondarySize * scale * 2 / 3,
                                    height: secondarySize * scale * 2 / 3
                                )
                                .foregroundStyle(.white)
                                .frame(width: secondarySize * scale, height: secondarySize * scale)
                                .background(ChahuaTheme.accent, in: Circle())
                        } else if let name = rootSender?.name {
                            AvatarView(
                                url: rootSender?.avatarUrl.flatMap(URL.init(string:)),
                                displayName: name, diameter: secondarySize)
                        }
                    }
                    .background {
                        Circle().fill(.background)
                            .overlay {
                                Circle().fill(ChahuaTheme.accent.opacity(isSelected ? 0.14 : 0))
                            }
                            .padding(-2)
                    }
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
                }
            }
    }
}
