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
    public let lastReadMessageId: String?
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
        lastReadMessageId: String? = nil,
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
        self.lastReadMessageId = lastReadMessageId
        self.subscribedAt = subscribedAt
        self.archived = archived
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
