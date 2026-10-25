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

    public init(showMembershipMessages: Bool) {
        self.showMembershipMessages = showMembershipMessages
    }
}

public struct UpdateChatSettingsBody: Codable, Hashable, Sendable {
    public let showMembershipMessages: Bool

    public init(showMembershipMessages: Bool) {
        self.showMembershipMessages = showMembershipMessages
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
