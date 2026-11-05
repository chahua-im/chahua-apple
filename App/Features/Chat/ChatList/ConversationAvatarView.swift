import ChahuaAPI
import SwiftUI

struct ConversationAvatarView: View {
    let item: ConversationListItem
    @ObservedObject var store: ChatStore
    var diameter: CGFloat = 40
    var isSelected = false

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
                    chatKind: thread.chatKind, peer: thread.peer,
                    rootSender: thread.threadRootMessage.sender,
                    diameter: diameter, isSelected: isSelected)
            }
        }
    }
}

struct ThreadAvatarView: View {
    let chatName: String
    let chatAvatar: String?
    let chatKind: ChatKind?
    let peer: MemberSummary?
    let rootSender: User?
    var diameter: CGFloat = 48
    var isSelected = false
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var isDM: Bool { chatKind == .dm }
    private var primaryName: String {
        if isDM {
            return peer?.username ?? chatName
        }
        return chatName
    }
    private var primaryURL: URL? {
        let value =
            isDM
            ? (peer?.avatarUrl ?? chatAvatar)
            : chatAvatar
        return value.flatMap(URL.init(string:))
    }

    var body: some View {
        let secondarySize = max(16, (diameter * 0.55).rounded())
        AvatarView(url: primaryURL, displayName: primaryName, diameter: diameter)
            .overlay(alignment: .topTrailing) {
                // Do not infer group-vs-DM styling while the parent kind is unresolved.
                if isDM || (chatKind == .group && !(rootSender?.name ?? "").isEmpty) {
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
