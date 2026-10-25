import Foundation

/// Directory and friendship contracts used by the PWA. IDs and group cursors stay opaque.
public protocol SocialAPIClient: Sendable {
    func searchUsers(query: String) async throws -> SearchUsersResponse
    func searchJoinedGroups(query: String, after: String?) async throws -> SocialGroupsResponse
    func friendAddInfo(uid: Int32) async throws -> FriendVerificationSettings
    func friendVerificationSettings() async throws -> FriendVerificationSettings
    func updateFriendVerificationSettings(_ settings: FriendVerificationSettings) async throws
        -> FriendVerificationSettings
    func listFriendRequests(archived: Bool) async throws -> FriendRequestsResponse
    func createFriendRequest(toUID: Int32, message: String?) async throws -> FriendRequest
    func decideFriendRequest(id: String, decision: FriendRequestDecision) async throws
    func blockedUsers() async throws -> BlockedUsersResponse
}

extension SocialAPIClient {
    public func searchUsers(query: String) async throws -> SearchUsersResponse {
        throw APIError.unavailable
    }
    public func searchJoinedGroups(query: String, after: String?) async throws
        -> SocialGroupsResponse
    { throw APIError.unavailable }
    public func friendAddInfo(uid: Int32) async throws -> FriendVerificationSettings {
        throw APIError.unavailable
    }
    public func friendVerificationSettings() async throws -> FriendVerificationSettings {
        throw APIError.unavailable
    }
    public func updateFriendVerificationSettings(_ settings: FriendVerificationSettings)
        async throws -> FriendVerificationSettings
    { throw APIError.unavailable }
    public func listFriendRequests(archived: Bool) async throws -> FriendRequestsResponse {
        throw APIError.unavailable
    }
    public func createFriendRequest(toUID: Int32, message: String?) async throws -> FriendRequest {
        throw APIError.unavailable
    }
    public func decideFriendRequest(id: String, decision: FriendRequestDecision) async throws {
        throw APIError.unavailable
    }
    public func blockedUsers() async throws -> BlockedUsersResponse { throw APIError.unavailable }
}

public struct SearchUsersResponse: Codable, Sendable {
    public let members: [MemberSummary]
    public let excluded: [MemberSummary]
}

public struct SocialGroupSummary: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let avatar: String?
    public let description: String?
}

public struct SocialGroupsResponse: Codable, Sendable {
    public let groups: [SocialGroupSummary]
    public let nextCursor: String?
}

public enum FriendVerificationMode: String, Codable, CaseIterable, Sendable {
    case direct
    case needMessage = "need_message"
    case question
    case forbid
}

public struct FriendVerificationSettings: Codable, Equatable, Sendable {
    public let mode: FriendVerificationMode
    public let question: String?

    public init(mode: FriendVerificationMode, question: String? = nil) {
        self.mode = mode
        self.question = question
    }
}

public enum FriendRequestDirection: String, Codable, Sendable {
    case incoming, outgoing
}

public enum FriendRequestDecision: String, Sendable {
    case accept, reject, archive
}

public struct FriendRequest: Codable, Identifiable, Sendable {
    public let id: String
    public let from: MemberSummary
    public let to: MemberSummary
    public let createdAt: Date
    public let decidedAt: Date?
    public let message: String?
    public let question: String?
    public let status: FriendRequestStatus
    /// Only history/list responses include direction; create/decision responses do not.
    public let direction: FriendRequestDirection?
}

public struct FriendRequestsResponse: Codable, Sendable {
    public let requests: [FriendRequest]
}

public struct BlockedUser: Codable, Identifiable, Sendable {
    public let since: Date
    public let user: MemberSummary
    public var id: Int32 { user.uid }
}

public struct BlockedUsersResponse: Codable, Sendable {
    public let blocks: [BlockedUser]
}
