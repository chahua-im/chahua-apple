/// Base sharing policy for individual online status and last-seen activity together.
/// Discoverability, blocking, and the other person's policy still apply.
public enum PresenceVisibility: String, Codable, CaseIterable, Sendable {
    case everyone
    case friends
    case nobody
}

/// Authoritative settings returned by `GET` and `PUT /me/presence-settings`.
/// A failed read must not be interpreted as the server's default policy.
public struct PresenceSettingsResponse: Codable, Equatable, Sendable {
    public let visibility: PresenceVisibility

    public init(visibility: PresenceVisibility) {
        self.visibility = visibility
    }
}

/// Both friends' effective policies must allow exact online/last-seen sharing.
public enum FriendPresenceOverride: String, Codable, CaseIterable, Sendable {
    case inherit
    case share
    case hide
}

public struct FriendPresenceSettingsResponse: Codable, Equatable, Sendable {
    public let override: FriendPresenceOverride

    public init(override: FriendPresenceOverride) {
        self.override = override
    }
}

public struct User: Codable, Hashable, Sendable {
    public let uid: Int32
    public let gender: Int32
    public let name: String?
    public let avatarUrl: String?
    public let userGroup: UserGroupTagInfo?

    public init(
        uid: Int32, gender: Int32, name: String?, avatarUrl: String?, userGroup: UserGroupTagInfo?
    ) {
        self.uid = uid
        self.gender = gender
        self.name = name
        self.avatarUrl = avatarUrl
        self.userGroup = userGroup
    }
}

extension MeResponse {
    /// The signed-in user in message-sender form, e.g. for sends not yet acknowledged.
    public var asSender: User {
        User(uid: uid, gender: gender, name: username, avatarUrl: avatarUrl, userGroup: userGroup)
    }
}

public struct UserGroupTagInfo: Codable, Hashable, Sendable {
    public let groupId: Int32
    public let name: String?
    public let chatGroupColor: String?
    public let chatGroupColorDark: String?
}

public struct MentionInfo: Codable, Hashable, Sendable {
    public let uid: Int32
    public let gender: Int32
    public let username: String?
    public let avatarUrl: String?
    public let userGroup: UserGroupTagInfo?
}

public struct MemberResponse: Codable, Hashable, Sendable, Identifiable {
    public let uid: Int32
    public let username: String?
    public let avatarUrl: String?
    public let role: GroupRole

    public var id: Int32 { uid }

    public init(
        uid: Int32, username: String? = nil, avatarUrl: String? = nil, role: GroupRole = .member
    ) {
        self.uid = uid
        self.username = username
        self.avatarUrl = avatarUrl
        self.role = role
    }
}

public struct ListMembersResponse: Codable, Hashable, Sendable {
    public let members: [MemberResponse]
    public let nextCursor: Int32?
    public let canManageMembers: Bool

    public init(members: [MemberResponse], nextCursor: Int32?, canManageMembers: Bool) {
        self.members = members
        self.nextCursor = nextCursor
        self.canManageMembers = canManageMembers
    }
}

public struct MeResponse: Codable, Hashable, Sendable {
    public let uid: Int32
    public let username: String
    public let gender: Int32
    public let stickerPackOrder: [StickerPackOrderItem]
    public let permissions: [String]
    public let avatarUrl: String?
    public let userGroup: UserGroupTagInfo?
    public let muteGroupChatsByDefault: Bool?
    public let muteDirectChatsByDefault: Bool?
}

public struct StickerPackOrderItem: Codable, Hashable, Sendable {
    public let stickerPackId: String
    public let lastUsedOn: Int64
}

/// One preference mutation for `PUT /users/me/stickerpack-order`.
public struct StickerPackOrderUpdate: Codable, Hashable, Sendable {
    public let stickerPackId: String
    public let lastUsedOn: Int64
    public let isAutoSort: Bool?

    public init(stickerPackId: String, lastUsedOn: Int64, isAutoSort: Bool? = nil) {
        self.stickerPackId = stickerPackId
        self.lastUsedOn = lastUsedOn
        self.isAutoSort = isAutoSort
    }
}
