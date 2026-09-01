import Foundation

/// Server chat classification used by `ChatListItem`.
///
/// A direct-message item carries the other participant in `peer`; a group item
/// uses its own `name` and `avatar` fields.
public enum ChatKind: String, Codable, Hashable, Sendable {
    case group
    case dm
}

/// One current-member chat projection returned by `GET /chats`.
///
/// The list is server ordered. This is a summary, not a conversation timeline:
/// `lastMessage` is a `MessagePreview`, while full messages arrive through
/// `listMessages(chatID:query:)`.
public struct ChatListItem: Codable, Hashable, Identifiable, Sendable {
    /// Opaque chat identifier used by all chat-scoped routes.
    public let id: String
    /// Group display name; may also be a fallback name for a direct message.
    public let name: String?
    /// Group avatar URL.
    public let avatar: String?
    /// Timestamp for ordering/representing the latest message.
    public let lastMessageAt: Date?
    /// Server-calculated unread count for the current member.
    public let unreadCount: Int64
    /// Current member's last-read message ID.
    public let lastReadMessageId: String?
    /// Summary of the latest message, not a complete cached message.
    public let lastMessage: MessagePreview?
    /// Current member's mute expiry.
    public let mutedUntil: Date?
    /// Whether this chat is archived for the current member.
    public let archived: Bool
    /// Whether this item represents a group or direct-message chat.
    public let kind: ChatKind
    /// Other participant for a direct message; absent for a group.
    public let peer: MemberSummary?

    public init(
        id: String,
        name: String? = nil,
        avatar: String? = nil,
        lastMessageAt: Date? = nil,
        unreadCount: Int64,
        lastReadMessageId: String? = nil,
        lastMessage: MessagePreview? = nil,
        mutedUntil: Date? = nil,
        archived: Bool,
        kind: ChatKind,
        peer: MemberSummary? = nil
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.lastReadMessageId = lastReadMessageId
        self.lastMessage = lastMessage
        self.mutedUntil = mutedUntil
        self.archived = archived
        self.kind = kind
        self.peer = peer
    }
}

/// Compact participant projection used for direct-message peer identity.
public struct MemberSummary: Codable, Hashable, Sendable {
    /// Stable user ID.
    public let uid: Int32
    /// Participant display name.
    public let username: String?
    /// Participant avatar URL.
    public let avatarUrl: String?
    /// Server user gender value.
    public let gender: Int32
    /// Optional participant group tag.
    public let userGroup: UserGroupTagInfo?

    public init(
        uid: Int32,
        username: String? = nil,
        avatarUrl: String? = nil,
        gender: Int32,
        userGroup: UserGroupTagInfo? = nil
    ) {
        self.uid = uid
        self.username = username
        self.avatarUrl = avatarUrl
        self.gender = gender
        self.userGroup = userGroup
    }
}

/// One cursor page returned by `GET /chats`.
///
/// Use `nextCursor` as `ListChatsQuery.after` to request the next server page.
public struct ListChatsResponse: Codable, Hashable, Sendable {
    /// Server-ordered chat summaries.
    public let chats: [ChatListItem]
    /// Opaque cursor for the next page, or `nil` when no next page exists.
    public let nextCursor: String?

    public init(chats: [ChatListItem], nextCursor: String? = nil) {
        self.chats = chats
        self.nextCursor = nextCursor
    }
}
