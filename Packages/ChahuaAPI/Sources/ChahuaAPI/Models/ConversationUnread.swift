import Foundation

public struct UnreadMentionIDsResponse: Codable, Hashable, Sendable {
    public let messageIds: [MessageID]

    public init(messageIds: [MessageID]) {
        self.messageIds = messageIds
    }
}

public struct UnreadReactionIDsResponse: Codable, Hashable, Sendable {
    public let messageIds: [MessageID]
    /// Opaque server snapshot boundary, not a message ID or a locally generated date.
    public let readThrough: String

    public init(messageIds: [MessageID], readThrough: String) {
        self.messageIds = messageIds
        self.readThrough = readThrough
    }
}

public struct UnreadReactionsAckResponse: Codable, Hashable, Sendable {
    public let unreadReactions: Int64

    public init(unreadReactions: Int64) {
        self.unreadReactions = unreadReactions
    }
}

public enum ConversationCategory: String, Codable, Hashable, Sendable {
    case group
    case dm
    case groupThread
    case dmThread
}

public struct ConversationRef: Codable, Hashable, Sendable {
    public let chatId: String
    public let threadId: MessageID?

    public init(chatId: String, threadId: MessageID? = nil) {
        self.chatId = chatId
        self.threadId = threadId
    }
}

/// Categories and explicit inclusions form a union; exclusions take precedence.
/// Membership, subscription and the archive filter still apply to explicit inclusions.
public struct ConversationSelector: Codable, Hashable, Sendable {
    public let archived: Bool?
    public let categories: [ConversationCategory]?
    public let exclude: [ConversationRef]?
    public let include: [ConversationRef]?

    public init(
        archived: Bool? = nil, categories: [ConversationCategory]? = nil,
        exclude: [ConversationRef]? = nil, include: [ConversationRef]? = nil
    ) {
        self.archived = archived
        self.categories = categories
        self.exclude = exclude
        self.include = include
    }
}

public struct ConversationView: Codable, Hashable, Sendable {
    public let key: String
    public let selector: ConversationSelector

    public init(key: String, selector: ConversationSelector) {
        self.key = key
        self.selector = selector
    }
}

public struct ConversationUnreadRequest: Codable, Hashable, Sendable {
    public let views: [ConversationView]

    public init(views: [ConversationView]) {
        self.views = views
    }
}

public struct ConversationUnreadSummary: Codable, Hashable, Sendable {
    public let key: String
    /// Group mentions/replies, including muted conversations, once per message; capped at 1000.
    public let unreadAttentionCount: Int64
    public let unreadConversationCount: Int64
    /// Includes muted conversations; capped at 1000.
    public let unreadMessageCount: Int64
    /// Group mentions/replies in unmuted conversations; capped at 1000.
    public let unreadUnmutedAttentionCount: Int64
    public let unreadUnmutedConversationCount: Int64
    /// Includes DMs and threads; capped at 1000.
    public let unreadUnmutedMessageCount: Int64

    public init(
        key: String, unreadAttentionCount: Int64, unreadConversationCount: Int64,
        unreadMessageCount: Int64, unreadUnmutedAttentionCount: Int64,
        unreadUnmutedConversationCount: Int64, unreadUnmutedMessageCount: Int64
    ) {
        self.key = key
        self.unreadAttentionCount = unreadAttentionCount
        self.unreadConversationCount = unreadConversationCount
        self.unreadMessageCount = unreadMessageCount
        self.unreadUnmutedAttentionCount = unreadUnmutedAttentionCount
        self.unreadUnmutedConversationCount = unreadUnmutedConversationCount
        self.unreadUnmutedMessageCount = unreadUnmutedMessageCount
    }
}

public struct ConversationUnreadResponse: Codable, Hashable, Sendable {
    public let summaries: [ConversationUnreadSummary]

    public init(summaries: [ConversationUnreadSummary]) {
        self.summaries = summaries
    }
}
