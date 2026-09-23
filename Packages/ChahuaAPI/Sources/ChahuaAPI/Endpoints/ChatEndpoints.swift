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

/// Query fields accepted by `GET /group/{chatID}/members`.
public struct ListMembersQuery: Sendable, Equatable {
    public var q: String?
    /// The server supports `autocomplete` and `submitted` search modes.
    public var mode: String
    public var limit: Int
    /// Member UID returned as `ListMembersResponse.nextCursor`.
    public var after: Int32?

    public init(q: String? = nil, mode: String = "autocomplete", limit: Int = 8, after: Int32? = nil) {
        self.q = q
        self.mode = mode
        self.limit = limit
        self.after = after
    }

    var queryItems: [URLQueryItem] {
        [
            q.map { URLQueryItem(name: "q", value: $0) },
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "limit", value: String(limit)),
            after.map { URLQueryItem(name: "after", value: String($0)) },
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
    let durationSeconds: Int?
}

private struct UpdateGroupMemberRoleBody: Encodable {
    let role: GroupRole
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

    func unarchiveChat(chatID: String) async throws {
        try await send(HTTPRequestSpec(method: .delete, path: ["chats", chatID, "archive"]))
    }

    func muteChat(chatID: String, durationSeconds: Int?) async throws -> MuteResponse {
        try await send(
            HTTPRequestSpec.json(.put, ["group", chatID, "mute"], body: MuteBody(durationSeconds: durationSeconds)),
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

    func listMembers(chatID: String, query: ListMembersQuery) async throws -> ListMembersResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["group", chatID, "members"], query: query.queryItems),
            decoding: ListMembersResponse.self
        )
    }

    func updateGroupMemberRole(chatID: String, uid: Int32, role: GroupRole) async throws -> MemberResponse {
        try await send(
            HTTPRequestSpec.json(
                .patch, ["group", chatID, "members", String(uid)], body: UpdateGroupMemberRoleBody(role: role)),
            decoding: MemberResponse.self
        )
    }

    func removeGroupMember(chatID: String, uid: Int32) async throws {
        try await send(HTTPRequestSpec(method: .delete, path: ["group", chatID, "members", String(uid)]))
    }

    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["friends", String(peerUID)]),
            decoding: FriendRelationshipResponse.self
        )
    }
}
