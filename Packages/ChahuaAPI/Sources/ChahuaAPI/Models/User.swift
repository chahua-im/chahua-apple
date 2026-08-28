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

public struct MeResponse: Codable, Hashable, Sendable {
    public let uid: Int32
    public let username: String
    public let gender: Int32
    public let stickerPackOrder: [StickerPackOrderItem]
    public let permissions: [String]
    public let avatarUrl: String?
}

public struct StickerPackOrderItem: Codable, Hashable, Sendable {
    public let stickerPackId: String
    public let lastUsedOn: Int64
}
