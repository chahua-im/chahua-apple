import Foundation

/// Query fields accepted by `GET /threads` for the current user's subscriptions.
///
/// Set `archived` to `false` for active threads. Pass the response's opaque
/// `nextCursor` as `before` to fetch a later page without changing server ordering.
public struct ListThreadsQuery: Sendable, Equatable {
    public var limit: Int?
    public var before: String?
    public var archived: Bool?

    public init(limit: Int? = nil, before: String? = nil, archived: Bool? = nil) {
        self.limit = limit
        self.before = before
        self.archived = archived
    }

    var queryItems: [URLQueryItem] {
        [
            limit.map { URLQueryItem(name: "limit", value: String($0)) },
            before.map { URLQueryItem(name: "before", value: $0) },
            archived.map { URLQueryItem(name: "archived", value: String($0)) },
        ].compactMap { $0 }
    }
}

public extension ChahuaClient {
    func markThreadRead(chatID: String, threadID: String, messageID: String) async throws -> ReadStateResponse {
        try await send(
            HTTPRequestSpec.json(.post, ["chats", chatID, "threads", threadID, "read"], body: MarkReadBody(messageId: messageID)),
            decoding: ReadStateResponse.self
        )
    }

    /// Fetches one subscribed thread page with authenticated `GET /threads`.
    func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["threads"], query: query.queryItems),
            decoding: ListThreadsResponse.self
        )
    }

    /// Sends a reply with JSON `POST /chats/{chatID}/threads/{threadID}/messages`.
    func sendThreadMessage(
        chatID: String,
        threadID: String,
        body: CreateMessageBody
    ) async throws -> MessageResponse {
        try await send(
            HTTPRequestSpec.json(.post, ["chats", chatID, "threads", threadID, "messages"], body: body),
            decoding: MessageResponse.self
        )
    }
}
