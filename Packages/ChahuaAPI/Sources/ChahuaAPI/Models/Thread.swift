import Foundation

/// One subscribed thread projection returned by `GET /threads`.
///
/// A thread is identified by both `chatId` and `threadRootMessage.id`. Previews
/// provide display context only; fetch its timeline with `ListMessagesQuery.threadID`.
public struct ThreadListItem: Codable, Hashable, Sendable {
    public let chatId: String
    public let chatName: String
    public let chatAvatar: String?
    public let threadRootMessage: MessagePreview
    public let participants: [User]
    public let lastReply: MessagePreview?
    public let replyCount: Int64
    public let lastReplyAt: Date
    public let unreadCount: Int64
    public let unreadMentions: Int64
    public let unreadReactions: Int64
    public let lastReadMessageId: MessageID?
    /// Authorized receipt for replies in this topic, never its root message.
    public let peerLastReadMessageId: MessageID?
    /// Missing in older snapshots; default to DM so group-only attention is never inferred.
    public let chatKind: ChatKind
    public let subscribedAt: Date
    public let archived: Bool

    public init(
        chatId: String,
        chatName: String,
        chatAvatar: String? = nil,
        threadRootMessage: MessagePreview,
        participants: [User],
        lastReply: MessagePreview? = nil,
        replyCount: Int64,
        lastReplyAt: Date,
        unreadCount: Int64,
        unreadMentions: Int64 = 0,
        unreadReactions: Int64 = 0,
        lastReadMessageId: MessageID? = nil,
        peerLastReadMessageId: MessageID? = nil,
        chatKind: ChatKind = .dm,
        subscribedAt: Date,
        archived: Bool
    ) {
        self.chatId = chatId
        self.chatName = chatName
        self.chatAvatar = chatAvatar
        self.threadRootMessage = threadRootMessage
        self.participants = participants
        self.lastReply = lastReply
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.unreadCount = unreadCount
        self.unreadMentions = unreadMentions
        self.unreadReactions = unreadReactions
        self.lastReadMessageId = lastReadMessageId
        self.peerLastReadMessageId = peerLastReadMessageId
        self.chatKind = chatKind
        self.subscribedAt = subscribedAt
        self.archived = archived
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatId = try container.decode(String.self, forKey: .chatId)
        chatName = try container.decode(String.self, forKey: .chatName)
        chatAvatar = try container.decodeIfPresent(String.self, forKey: .chatAvatar)
        threadRootMessage = try container.decode(MessagePreview.self, forKey: .threadRootMessage)
        participants = try container.decode([User].self, forKey: .participants)
        lastReply = try container.decodeIfPresent(MessagePreview.self, forKey: .lastReply)
        replyCount = try container.decode(Int64.self, forKey: .replyCount)
        lastReplyAt = try container.decode(Date.self, forKey: .lastReplyAt)
        unreadCount = try container.decode(Int64.self, forKey: .unreadCount)
        unreadMentions = try container.decodeIfPresent(Int64.self, forKey: .unreadMentions) ?? 0
        unreadReactions = try container.decodeIfPresent(Int64.self, forKey: .unreadReactions) ?? 0
        lastReadMessageId = try container.decodeIfPresent(
            MessageID.self, forKey: .lastReadMessageId)
        peerLastReadMessageId = try container.decodeIfPresent(
            MessageID.self, forKey: .peerLastReadMessageId)
        chatKind = try container.decodeIfPresent(ChatKind.self, forKey: .chatKind) ?? .dm
        subscribedAt = try container.decode(Date.self, forKey: .subscribedAt)
        archived = try container.decode(Bool.self, forKey: .archived)
    }
}

/// One server-ordered page of subscribed threads.
public struct ListThreadsResponse: Codable, Hashable, Sendable {
    public let threads: [ThreadListItem]
    /// Opaque boundary passed as `ListThreadsQuery.before` for the next page.
    public let nextCursor: String?

    public init(threads: [ThreadListItem], nextCursor: String? = nil) {
        self.threads = threads
        self.nextCursor = nextCursor
    }
}
