import Foundation

/// Query fields accepted by `GET /chats`.
///
/// `after` is the opaque cursor from `ListChatsResponse.nextCursor`. Set
/// `archived` to `false` for active chats or `true` for archived chats; omit it
/// only when the server default is intended.
public struct ListChatsQuery: Sendable, Equatable {
    /// Maximum number of chats in the returned page.
    public var limit: Int64?
    /// Opaque cursor identifying the page boundary.
    public var after: String?
    /// Whether to return archived rather than active chats.
    public var archived: Bool?

    public init(limit: Int64? = nil, after: String? = nil, archived: Bool? = nil) {
        self.limit = limit
        self.after = after
        self.archived = archived
    }

    var queryItems: [URLQueryItem] {
        [
            limit.map { URLQueryItem(name: "limit", value: String($0)) },
            after.map { URLQueryItem(name: "after", value: $0) },
            archived.map { URLQueryItem(name: "archived", value: String($0)) },
        ].compactMap { $0 }
    }
}

public extension ChahuaClient {
    /// Fetches one server-ordered chat page with authenticated `GET /chats`.
    ///
    /// The client sends `limit`, `after`, and `archived` only when the
    /// corresponding `ListChatsQuery` fields are non-`nil`.
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: "/chats", query: query.queryItems),
            decoding: ListChatsResponse.self
        )
    }
}
