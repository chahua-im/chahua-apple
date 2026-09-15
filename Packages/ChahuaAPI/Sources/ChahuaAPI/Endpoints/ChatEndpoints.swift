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

public struct MuteResponse: Codable, Hashable, Sendable {
    public let mutedUntil: Date

    public init(mutedUntil: Date) {
        self.mutedUntil = mutedUntil
    }
}

private struct MuteBody: Encodable {
    // An absent duration requests the server's indefinite mute.
    let durationSeconds: Int? = nil
}

public extension ChahuaClient {
    func markChatUnread(chatID: String) async throws -> ReadStateResponse {
        try await send(
            HTTPRequestSpec(method: .post, path: ["chats", chatID, "unread"]),
            decoding: ReadStateResponse.self
        )
    }

    func archiveChat(chatID: String) async throws {
        try await send(HTTPRequestSpec(method: .put, path: ["chats", chatID, "archive"]))
    }

    func muteChat(chatID: String) async throws -> MuteResponse {
        try await send(
            HTTPRequestSpec.json(.put, ["group", chatID, "mute"], body: MuteBody()),
            decoding: MuteResponse.self
        )
    }

    func unmuteChat(chatID: String) async throws {
        try await send(HTTPRequestSpec(method: .delete, path: ["group", chatID, "mute"]))
    }

    /// Fetches one server-ordered chat page with authenticated `GET /chats`.
    ///
    /// The client sends `limit`, `after`, and `archived` only when the
    /// corresponding `ListChatsQuery` fields are non-`nil`.
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["chats"], query: query.queryItems),
            decoding: ListChatsResponse.self
        )
    }

    func groupInfo(chatID: String) async throws -> GroupInfoResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["group", chatID]),
            decoding: GroupInfoResponse.self
        )
    }

    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["friends", String(peerUID)]),
            decoding: FriendRelationshipResponse.self
        )
    }
}
