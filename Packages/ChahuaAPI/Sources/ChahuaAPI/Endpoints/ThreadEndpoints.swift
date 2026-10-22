import Foundation

/// Query fields accepted by `GET /threads` for the current user's subscriptions.
///
/// Set `archived` to `false` for active threads. Pass the response's opaque
/// `nextCursor` as `before` to fetch a later page without changing server ordering.
public struct ListThreadsQuery: Sendable, Equatable {
    public var limit: Int?
    public var before: String?
    public var archived: Bool?
    /// Restricts the page to one subscribed root while retaining the archive filter.
    public var rootId: MessageID?

    public init(
        limit: Int? = nil, before: String? = nil, archived: Bool? = nil,
        rootId: MessageID? = nil
    ) {
        self.limit = limit
        self.before = before
        self.archived = archived
        self.rootId = rootId
    }

    var queryItems: [URLQueryItem] {
        [
            limit.map { URLQueryItem(name: "limit", value: String($0)) },
            before.map { URLQueryItem(name: "before", value: $0) },
            archived.map { URLQueryItem(name: "archived", value: String($0)) },
            rootId.map { URLQueryItem(name: "rootId", value: $0.description) },
        ].compactMap { $0 }
    }
}

/// The current user's subscription to one thread, from `GET .../subscribe`.
///
/// Only subscribed threads appear in `GET /threads`; `archived` selects which list.
/// A thread the user never subscribed to reports `false` for both fields.
public struct ThreadSubscriptionStatus: Codable, Hashable, Sendable {
    public let subscribed: Bool
    public let archived: Bool

    public init(subscribed: Bool, archived: Bool) {
        self.subscribed = subscribed
        self.archived = archived
    }
}

extension ChahuaClient {
    public func threadReadState(chatID: String, threadID: String) async throws -> ReadStateResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "threads", threadID, "read-state"]),
            decoding: ReadStateResponse.self
        )
    }

    public func archiveThread(chatID: String, threadID: String) async throws {
        try await send(
            HTTPRequestSpec(method: .put, path: ["chats", chatID, "threads", threadID, "archive"]))
    }

    public func unarchiveThread(chatID: String, threadID: String) async throws {
        try await send(
            HTTPRequestSpec(
                method: .delete, path: ["chats", chatID, "threads", threadID, "archive"]))
    }

    public func threadSubscriptionStatus(chatID: String, threadID: String) async throws
        -> ThreadSubscriptionStatus
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "threads", threadID, "subscribe"]),
            decoding: ThreadSubscriptionStatus.self
        )
    }

    public func subscribeThread(chatID: String, threadID: String) async throws {
        try await send(
            HTTPRequestSpec(
                method: .put, path: ["chats", chatID, "threads", threadID, "subscribe"]))
    }

    public func markThreadRead(chatID: String, threadID: String, messageID: MessageID)
        async throws
        -> ReadStateResponse
    {
        try await send(
            HTTPRequestSpec.json(
                .post, ["chats", chatID, "threads", threadID, "read"],
                body: MarkReadBody(messageId: messageID)),
            decoding: ReadStateResponse.self
        )
    }

    /// Fetches one subscribed thread page with authenticated `GET /threads`.
    public func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["threads"], query: query.queryItems),
            decoding: ListThreadsResponse.self
        )
    }

    /// Sends a reply with JSON `POST /chats/{chatID}/threads/{threadID}/messages`.
    public func sendThreadMessage(
        chatID: String,
        threadID: String,
        body: CreateMessageBody
    ) async throws -> MessageResponse {
        try await send(
            HTTPRequestSpec.json(
                .post, ["chats", chatID, "threads", threadID, "messages"], body: body),
            decoding: MessageResponse.self
        )
    }
}
