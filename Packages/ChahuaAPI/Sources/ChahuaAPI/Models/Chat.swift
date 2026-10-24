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
    public let unreadMentions: Int64
    public let unreadReactions: Int64
    /// Current member's last-read message ID.
    public let lastReadMessageId: MessageID?
    /// Server-authorized peer receipt for this DM's main conversation only.
    public let peerLastReadMessageId: MessageID?
    /// Summary of the latest message, not a complete cached message.
    public let lastMessage: MessagePreview?
    /// Current member's mute expiry.
    public let mutedUntil: Date?
    public let muteOverride: Bool?
    public let isMuted: Bool?
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
        unreadMentions: Int64 = 0,
        unreadReactions: Int64 = 0,
        lastReadMessageId: MessageID? = nil,
        peerLastReadMessageId: MessageID? = nil,
        lastMessage: MessagePreview? = nil,
        mutedUntil: Date? = nil,
        muteOverride: Bool? = nil,
        isMuted: Bool? = nil,
        archived: Bool,
        kind: ChatKind,
        peer: MemberSummary? = nil
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.unreadMentions = unreadMentions
        self.unreadReactions = unreadReactions
        self.lastReadMessageId = lastReadMessageId
        self.peerLastReadMessageId = peerLastReadMessageId
        self.lastMessage = lastMessage
        self.mutedUntil = mutedUntil
        self.muteOverride = muteOverride
        self.isMuted = isMuted
        self.archived = archived
        self.kind = kind
        self.peer = peer
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        lastMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        unreadCount = try container.decode(Int64.self, forKey: .unreadCount)
        unreadMentions = try container.decodeIfPresent(Int64.self, forKey: .unreadMentions) ?? 0
        unreadReactions = try container.decodeIfPresent(Int64.self, forKey: .unreadReactions) ?? 0
        lastReadMessageId = try container.decodeIfPresent(
            MessageID.self, forKey: .lastReadMessageId)
        peerLastReadMessageId = try container.decodeIfPresent(
            MessageID.self, forKey: .peerLastReadMessageId)
        lastMessage = try container.decodeIfPresent(MessagePreview.self, forKey: .lastMessage)
        mutedUntil = try container.decodeIfPresent(Date.self, forKey: .mutedUntil)
        muteOverride = try container.decodeIfPresent(Bool.self, forKey: .muteOverride)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted)
        archived = try container.decode(Bool.self, forKey: .archived)
        kind = try container.decode(ChatKind.self, forKey: .kind)
        peer = try container.decodeIfPresent(MemberSummary.self, forKey: .peer)
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

public enum GroupRole: String, Codable, Hashable, Sendable {
    case member
    case admin
}

/// Membership and peer fields from `GET /group/{chatID}`.
public struct GroupInfoResponse: Codable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public let description: String?
    public let avatar: String?
    public let mutedUntil: Date?
    public let muteOverride: Bool?
    public let isMuted: Bool?
    public let myRole: GroupRole?
    public let kind: ChatKind
    public let peer: MemberSummary?

    public init(
        id: String, name: String? = nil, description: String? = nil, avatar: String? = nil,
        mutedUntil: Date? = nil, muteOverride: Bool? = nil, isMuted: Bool? = nil,
        myRole: GroupRole? = nil, kind: ChatKind,
        peer: MemberSummary? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.avatar = avatar
        self.mutedUntil = mutedUntil
        self.muteOverride = muteOverride
        self.isMuted = isMuted
        self.myRole = myRole
        self.kind = kind
        self.peer = peer
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        mutedUntil = try container.decodeIfPresent(Date.self, forKey: .mutedUntil)
        muteOverride = try container.decodeIfPresent(Bool.self, forKey: .muteOverride)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted)
        myRole = try container.decodeIfPresent(GroupRole.self, forKey: .myRole)
        kind = try container.decodeIfPresent(ChatKind.self, forKey: .kind) ?? .group
        peer = try container.decodeIfPresent(MemberSummary.self, forKey: .peer)
    }
}

/// The server-authoritative DM write decision from `GET /friends/{peerUID}`.
public struct FriendRelationshipResponse: Codable, Hashable, Sendable {
    public let peerUid: Int32
    public let canDm: Bool
    /// Omitted only by older servers; never infer friendship from DM write permission.
    public let isFriend: Bool?
    /// Unknown on older responses; callers must not assume the peer is unblocked.
    public let blocking: Bool?
}
