import Foundation

public enum NotificationSettingMode: String, Codable, Hashable, Sendable {
    case inherit, alwaysMuted, alwaysUnmuted, temporarilyMuted
}

public struct UpdateNotificationSettingRequest: Codable, Hashable, Sendable {
    public let mode: NotificationSettingMode
    public let durationSeconds: Int?

    public init(mode: NotificationSettingMode, durationSeconds: Int? = nil) {
        self.mode = mode
        self.durationSeconds = durationSeconds
    }
}

public struct NotificationSettingsResponse: Codable, Hashable, Sendable {
    public let muteGroupChatsByDefault: Bool
    public let muteDirectChatsByDefault: Bool

    public init(muteGroupChatsByDefault: Bool, muteDirectChatsByDefault: Bool) {
        self.muteGroupChatsByDefault = muteGroupChatsByDefault
        self.muteDirectChatsByDefault = muteDirectChatsByDefault
    }

    public func mutedByDefault(kind: ChatKind) -> Bool {
        kind == .dm ? muteDirectChatsByDefault : muteGroupChatsByDefault
    }
}

public struct UpdateNotificationSettingsRequest: Encodable, Sendable {
    public let muteGroupChatsByDefault: Bool?
    public let muteDirectChatsByDefault: Bool?

    public init(kind: ChatKind, muted: Bool) {
        muteGroupChatsByDefault = kind == .group ? muted : nil
        muteDirectChatsByDefault = kind == .dm ? muted : nil
    }
}

/// Full notification snapshot: absent override/expiry clears that field.
public struct ChatNotificationSettingResponse: Codable, Hashable, Sendable {
    public let chatId: String
    public let kind: ChatKind
    public let archived: Bool
    public let muteOverride: Bool?
    public let mutedUntil: Date?
    public let isMuted: Bool

    public init(
        chatId: String, kind: ChatKind, archived: Bool, muteOverride: Bool? = nil,
        mutedUntil: Date? = nil, isMuted: Bool
    ) {
        self.chatId = chatId
        self.kind = kind
        self.archived = archived
        self.muteOverride = muteOverride
        self.mutedUntil = mutedUntil
        self.isMuted = isMuted
    }
}

public struct NotificationException: Codable, Hashable, Identifiable, Sendable {
    public let chatId: String
    public let kind: ChatKind
    public let archived: Bool
    public let muteOverride: Bool?
    public let mutedUntil: Date?
    public let isMuted: Bool
    public let name: String
    public let avatar: String?
    public let peer: MemberSummary?
    public var id: String { chatId }
}

public struct NotificationExceptionsResponse: Codable, Sendable {
    public let exceptions: [NotificationException]
    public let nextCursor: String?
    public let totalCount: Int
}

public struct NotificationExceptionsCleared: Codable, Sendable {
    public let chatIds: [String]
    public let kind: ChatKind
}

extension ChatListItem {
    /// Temporary mute wins; expiry restores the saved exception or account default.
    public func notificationMuted(defaults: NotificationSettingsResponse?, now: Date = Date())
        -> Bool
    {
        if let mutedUntil, mutedUntil > now { return true }
        return notificationPermanentlyMuted(defaults: defaults)
    }

    public func notificationPermanentlyMuted(defaults: NotificationSettingsResponse?) -> Bool {
        muteOverride ?? defaults?.mutedByDefault(kind: kind)
            ?? (isMuted == true && mutedUntil == nil)
    }
}
