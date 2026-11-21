import Foundation

/// One atomic account-list projection. Reset cursors start a replacement baseline;
/// callers follow the returned cursor through enumeration and catch-up.
public struct ConversationDifference: Codable, Sendable {
    public let cursor: String
    public let complete: Bool
    /// Open-ended server reason. Every non-nil value has the same reset semantics.
    public let reset: String?
    public let chatSettings: ChatSettings
    public let notificationSettings: NotificationSettingsResponse
    public let chats: [ChatListItem]
    public let threads: [ThreadListItem]
    public let latestMessages: [MessageResponse]
    public let removed: [ConversationRef]

    public init(
        cursor: String, complete: Bool, reset: String? = nil,
        chatSettings: ChatSettings, notificationSettings: NotificationSettingsResponse,
        chats: [ChatListItem] = [], threads: [ThreadListItem] = [],
        latestMessages: [MessageResponse] = [], removed: [ConversationRef] = []
    ) {
        self.cursor = cursor
        self.complete = complete
        self.reset = reset
        self.chatSettings = chatSettings
        self.notificationSettings = notificationSettings
        self.chats = chats
        self.threads = threads
        self.latestMessages = latestMessages
        self.removed = removed
    }
}
