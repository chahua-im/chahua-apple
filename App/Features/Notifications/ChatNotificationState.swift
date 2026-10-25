import ChahuaAPI
import Foundation

extension ChatListItem {
    func withNotificationState(
        mutedUntil: Date?, muteOverride: Bool?, isMuted: Bool?, archived: Bool
    ) -> Self {
        Self(
            id: id, name: name, avatar: avatar, lastMessageAt: lastMessageAt,
            unreadCount: unreadCount, unreadMentions: unreadMentions,
            unreadReactions: unreadReactions,
            lastReadMessageId: lastReadMessageId, peerLastReadMessageId: peerLastReadMessageId,
            lastMessage: lastMessage, mutedUntil: mutedUntil, muteOverride: muteOverride,
            isMuted: isMuted, archived: archived, kind: kind, peer: peer,
            membershipMessagePolicy: membershipMessagePolicy)
    }
}
