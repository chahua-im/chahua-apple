import Foundation

/// Authoritative current-member read state returned by chat and thread read endpoints.
public struct ReadStateResponse: Codable, Hashable, Sendable {
    public let lastReadMessageId: MessageID?
    public let unreadCount: Int64
    public let unreadMentions: Int64
    public let unreadReactions: Int64

    public init(
        lastReadMessageId: MessageID?, unreadCount: Int64, unreadMentions: Int64 = 0,
        unreadReactions: Int64 = 0
    ) {
        self.lastReadMessageId = lastReadMessageId
        self.unreadCount = unreadCount
        self.unreadMentions = unreadMentions
        self.unreadReactions = unreadReactions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastReadMessageId = try container.decodeIfPresent(
            MessageID.self, forKey: .lastReadMessageId)
        unreadCount = try container.decode(Int64.self, forKey: .unreadCount)
        unreadMentions = try container.decodeIfPresent(Int64.self, forKey: .unreadMentions) ?? 0
        unreadReactions = try container.decodeIfPresent(Int64.self, forKey: .unreadReactions) ?? 0
    }
}

struct MarkReadBody: Encodable {
    let messageId: MessageID
}

/// Query fields accepted by `GET /chats/{chatID}/messages`.
///
/// Cursors are message IDs. A request may select one position policy
/// (`before`, `around`, or `after`); callers should use `olderCursor`/`newerCursor`
/// from the response for subsequent paging.
public struct ListMessagesQuery: Sendable, Equatable {
    /// Return messages older than this cursor.
    public var before: MessageID?
    /// Return a page centered on this message cursor.
    public var around: MessageID?
    /// Return messages newer than this cursor.
    public var after: MessageID?
    /// Maximum messages in the returned page.
    public var max: Int64?
    /// Restrict the page to the given thread root ID.
    public var threadID: String?

    public init(
        before: MessageID? = nil,
        around: MessageID? = nil,
        after: MessageID? = nil,
        max: Int64? = nil,
        threadID: String? = nil
    ) {
        self.before = before
        self.around = around
        self.after = after
        self.max = max
        self.threadID = threadID
    }

    var queryItems: [URLQueryItem] {
        [
            before.map { URLQueryItem(name: "before", value: $0.description) },
            around.map { URLQueryItem(name: "around", value: $0.description) },
            after.map { URLQueryItem(name: "after", value: $0.description) },
            max.map { URLQueryItem(name: "max", value: String($0)) },
            threadID.map { URLQueryItem(name: "threadId", value: $0) },
        ].compactMap { $0 }
    }
}

/// Result ordering accepted by `GET /chats/{chatID}/messages/search`.
public enum MessageSearchSort: String, Sendable, Equatable, CaseIterable {
    /// Search-engine relevance, newest first among equal matches. The server default.
    case relevance
    /// Newest matching message first.
    case newest
}

/// Query fields accepted by `GET /chats/{chatID}/messages/search`.
///
/// The server rejects queries shorter than two normalized characters and result
/// windows whose `offset + limit` exceeds 1,000; it clamps `limit` to 1–100.
public struct SearchMessagesQuery: Sendable, Equatable {
    public var q: String
    public var sort: MessageSearchSort
    public var limit: Int?
    public var offset: Int?

    public init(
        q: String, sort: MessageSearchSort = .relevance, limit: Int? = nil, offset: Int? = nil
    ) {
        self.q = q
        self.sort = sort
        self.limit = limit
        self.offset = offset
    }

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "sort", value: sort.rawValue),
            limit.map { URLQueryItem(name: "limit", value: String($0)) },
            offset.map { URLQueryItem(name: "offset", value: String($0)) },
        ].compactMap { $0 }
    }
}

extension ChahuaClient {
    public func markChatRead(chatID: String, messageID: MessageID) async throws
        -> ReadStateResponse
    {
        try await send(
            HTTPRequestSpec.json(
                .post, ["chats", chatID, "read"], body: MarkReadBody(messageId: messageID)),
            decoding: ReadStateResponse.self
        )
    }

    /// Fetches a message page with authenticated `GET /chats/{chatID}/messages`.
    public func listMessages(
        chatID: String,
        query: ListMessagesQuery = .init()
    ) async throws -> ListMessagesResponse {
        try await send(
            HTTPRequestSpec(
                method: .get,
                path: ["chats", chatID, "messages"],
                query: query.queryItems
            ),
            decoding: ListMessagesResponse.self
        )
    }

    /// Searches published text messages with authenticated `GET /chats/{chatID}/messages/search`.
    public func searchMessages(chatID: String, query: SearchMessagesQuery) async throws
        -> SearchMessagesResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get,
                path: ["chats", chatID, "messages", "search"],
                query: query.queryItems
            ),
            decoding: SearchMessagesResponse.self
        )
    }

    /// Sends a message with authenticated JSON `POST /chats/{chatID}/messages`.
    public func sendMessage(
        chatID: String,
        body: CreateMessageBody
    ) async throws -> MessageResponse {
        try await send(
            HTTPRequestSpec.json(.post, ["chats", chatID, "messages"], body: body),
            decoding: MessageResponse.self
        )
    }

    /// Fetches a recipient-personalized, authoritative message snapshot.
    public func getMessage(chatID: String, messageID: MessageID) async throws -> MessageResponse {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "messages", messageID.description]),
            decoding: MessageResponse.self
        )
    }

    /// Fetches every reactor for each emoji on a message.
    public func getReactionDetails(chatID: String, messageID: MessageID) async throws
        -> ReactionDetailResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get,
                path: ["chats", chatID, "messages", messageID.description, "reactions"]),
            decoding: ReactionDetailResponse.self
        )
    }

    /// Replaces the text of an existing message.
    public func updateMessage(
        chatID: String,
        messageID: MessageID,
        body: UpdateMessageBody
    ) async throws -> MessageResponse {
        try await send(
            HTTPRequestSpec.json(
                .patch, ["chats", chatID, "messages", messageID.description], body: body),
            decoding: MessageResponse.self
        )
    }

    /// Recalls a message. Successful deletion returns an empty 204 response.
    public func deleteMessage(chatID: String, messageID: MessageID) async throws {
        try await send(
            HTTPRequestSpec(
                method: .delete, path: ["chats", chatID, "messages", messageID.description]))
    }

    /// Atomically recalls up to 100 messages after whole-batch server validation.
    public func bulkDeleteMessages(chatID: String, body: BulkDeleteMessagesBody) async throws
        -> BulkDeletedPayload
    {
        try await send(
            HTTPRequestSpec.json(.post, ["chats", chatID, "messages", "bulk-delete"], body: body),
            decoding: BulkDeletedPayload.self)
    }

    /// Adds the current user's reaction. The server returns an empty 204 response.
    public func putReaction(chatID: String, messageID: MessageID, emoji: String) async throws {
        try await send(
            HTTPRequestSpec(
                method: .put,
                path: ["chats", chatID, "messages", messageID.description, "reactions", emoji]))
    }

    /// Removes the current user's reaction. Emoji remains one encoded path segment.
    public func deleteReaction(chatID: String, messageID: MessageID, emoji: String) async throws {
        try await send(
            HTTPRequestSpec(
                method: .delete,
                path: ["chats", chatID, "messages", messageID.description, "reactions", emoji])
        )
    }
}
public struct UpdateMessageBody: Codable, Hashable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct BulkDeleteMessagesBody: Codable, Hashable, Sendable {
    public let messageIds: [MessageID]

    public init(messageIds: [MessageID]) {
        self.messageIds = messageIds
    }
}
