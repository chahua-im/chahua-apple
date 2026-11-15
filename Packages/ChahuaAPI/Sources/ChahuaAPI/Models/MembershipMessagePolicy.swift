public enum MembershipMessageVisibility: String, Codable, CaseIterable, Hashable, Sendable {
    case members
    case admins
    case nobody
}

public struct MembershipMessagePolicy: Codable, Hashable, Sendable {
    public let visibility: MembershipMessageVisibility
    public let canView: Bool

    public init(visibility: MembershipMessageVisibility, canView: Bool) {
        self.visibility = visibility
        self.canView = canView
    }
}

public struct ChatSettings: Codable, Hashable, Sendable {
    public let showMembershipMessages: Bool
    public let showUnreadMessageCount: Bool

    public init(showMembershipMessages: Bool, showUnreadMessageCount: Bool = false) {
        self.showMembershipMessages = showMembershipMessages
        self.showUnreadMessageCount = showUnreadMessageCount
    }
}

public struct UpdateChatSettingsBody: Codable, Hashable, Sendable {
    public let showMembershipMessages: Bool?
    public let showUnreadMessageCount: Bool?

    public init(showMembershipMessages: Bool? = nil, showUnreadMessageCount: Bool? = nil) {
        self.showMembershipMessages = showMembershipMessages
        self.showUnreadMessageCount = showUnreadMessageCount
    }
}

/// Invalidates cached group policy; the server intentionally sends no role-dependent policy here.
public struct MembershipMessagePolicyChangedPayload: Codable, Hashable, Sendable {
    public let chatId: String

    public init(chatId: String) {
        self.chatId = chatId
    }
}

public struct ChatMembershipChangedPayload: Codable, Hashable, Sendable {
    public let chatId: String

    public init(chatId: String) {
        self.chatId = chatId
    }
}
