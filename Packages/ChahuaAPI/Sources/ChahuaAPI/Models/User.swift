public struct User: Codable, Hashable, Sendable {
    public let uid: Int32
    public let gender: Int32
    public let name: String?
    public let avatarUrl: String?
    public let userGroup: UserGroupTagInfo?
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

    public var id: Int32 { uid }

    public init(uid: Int32, username: String? = nil, avatarUrl: String? = nil) {
        self.uid = uid
        self.username = username
        self.avatarUrl = avatarUrl
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
}

public struct StickerPackOrderItem: Codable, Hashable, Sendable {
    public let stickerPackId: String
    public let lastUsedOn: Int64
}
