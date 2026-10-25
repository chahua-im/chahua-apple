import Foundation

extension ChahuaClient {
    public func searchUsers(query: String) async throws -> SearchUsersResponse {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["users", "search"],
                query: [
                    URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "40"),
                ]), decoding: SearchUsersResponse.self)
    }

    public func searchJoinedGroups(query: String, after: String?) async throws
        -> SocialGroupsResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["group"],
                query: [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "mode", value: "submitted"),
                    URLQueryItem(name: "scope", value: "joined"),
                    URLQueryItem(name: "limit", value: "40"),
                    after.map { URLQueryItem(name: "after", value: $0) },
                ].compactMap { $0 }), decoding: SocialGroupsResponse.self)
    }

    public func friendAddInfo(uid: Int32) async throws -> FriendVerificationSettings {
        try await send(
            HTTPRequestSpec(method: .get, path: ["friends", "add-info", String(uid)]),
            decoding: FriendVerificationSettings.self)
    }

    public func friendVerificationSettings() async throws -> FriendVerificationSettings {
        try await send(
            HTTPRequestSpec(method: .get, path: ["friends", "me", "settings"]),
            decoding: FriendVerificationSettings.self)
    }

    public func updateFriendVerificationSettings(_ settings: FriendVerificationSettings)
        async throws -> FriendVerificationSettings
    {
        try await send(
            HTTPRequestSpec.json(.put, ["friends", "me", "settings"], body: settings),
            decoding: FriendVerificationSettings.self)
    }

    public func listFriendRequests(archived: Bool) async throws -> FriendRequestsResponse {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["friends", "requests"],
                query: [
                    URLQueryItem(name: "archived", value: String(archived))
                ]), decoding: FriendRequestsResponse.self)
    }

    public func createFriendRequest(toUID: Int32, message: String?) async throws -> FriendRequest {
        try await send(
            HTTPRequestSpec.json(
                .post, ["friends", "requests"],
                body: CreateFriendRequestBody(toUid: toUID, message: message)),
            decoding: FriendRequest.self)
    }

    public func decideFriendRequest(id: String, decision: FriendRequestDecision) async throws {
        let request = HTTPRequestSpec(
            method: decision == .archive ? .put : .post,
            path: ["friends", "requests", id, decision.rawValue])
        if decision == .archive {
            try await send(request)
        } else {
            _ = try await send(request, decoding: FriendRequest.self)
        }
    }

    public func blockedUsers() async throws -> BlockedUsersResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["blocks"]), decoding: BlockedUsersResponse.self)
    }

    public func removeFriend(peerUID: Int32) async throws {
        try await send(HTTPRequestSpec(method: .delete, path: ["friends", String(peerUID)]))
    }

    public func blockUser(uid: Int32) async throws {
        try await send(HTTPRequestSpec.json(.post, ["blocks"], body: BlockUserBody(uid: uid)))
    }

    public func unblockUser(uid: Int32) async throws {
        try await send(HTTPRequestSpec(method: .delete, path: ["blocks", String(uid)]))
    }
}

private struct BlockUserBody: Encodable {
    let uid: Int32
}

private struct CreateFriendRequestBody: Encodable {
    let toUid: Int32
    let message: String?
}
