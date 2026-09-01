import Foundation

/// Query fields accepted by `GET /chats/{chatID}/messages`.
///
/// Cursors are opaque server strings. A request may select one position policy
/// (`before`, `around`, or `after`); callers should preserve server ordering and
/// use `olderCursor`/`newerCursor` from the response for subsequent paging.
public struct ListMessagesQuery: Sendable, Equatable {
    /// Return messages older than this cursor.
    public var before: String?
    /// Return a page centered on this message cursor.
    public var around: String?
    /// Return messages newer than this cursor.
    public var after: String?
    /// Maximum messages in the returned page.
    public var max: Int64?
    /// Restrict the page to the given thread root ID.
    public var threadID: String?

    public init(
        before: String? = nil,
        around: String? = nil,
        after: String? = nil,
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
            before.map { URLQueryItem(name: "before", value: $0) },
            around.map { URLQueryItem(name: "around", value: $0) },
            after.map { URLQueryItem(name: "after", value: $0) },
            max.map { URLQueryItem(name: "max", value: String($0)) },
            threadID.map { URLQueryItem(name: "thread_id", value: $0) },
        ].compactMap { $0 }
    }
}

public extension ChahuaClient {
    /// Fetches a message page with authenticated `GET /chats/{chatID}/messages`.
    func listMessages(
        chatID: String,
        query: ListMessagesQuery = .init()
    ) async throws -> ListMessagesResponse {
        try await send(
            HTTPRequestSpec(
                method: .get,
                path: "/chats/\(chatID)/messages",
                query: query.queryItems
            ),
            decoding: ListMessagesResponse.self
        )
    }

    /// Sends a message with authenticated JSON `POST /chats/{chatID}/messages`.
    func sendMessage(
        chatID: String,
        body: CreateMessageBody
    ) async throws -> MessageResponse {
        try await send(
            HTTPRequestSpec.json(.post, "/chats/\(chatID)/messages", body: body),
            decoding: MessageResponse.self
        )
    }
}
