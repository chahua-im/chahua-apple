import Foundation

public enum GroupInviteType: String, Codable, Hashable, CaseIterable, Sendable {
    case generic, targeted, membership
}

public struct GroupInvite: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let chatId: String
    public let code: String
    public let createdAt: Date
    public let creatorUid: Int32?
    public let inviteType: GroupInviteType
    public let targetUid: Int32?
    public let requiredChatId: String?
    public let expiresAt: Date?
    public let revokedAt: Date?
    public let usedAt: Date?

    public var status: String {
        if revokedAt != nil { return "Revoked" }
        if usedAt != nil { return "Used" }
        if let expiresAt, expiresAt <= Date() { return "Expired" }
        return "Active"
    }
    public var isActive: Bool { status == "Active" }
}

public struct GroupInvitePreview: Codable, Sendable {
    public let alreadyMember: Bool
    public let chat: GroupInfoResponse
    public let invite: GroupInvite
}

public struct GroupInvitesPage: Codable, Sendable {
    public let invites: [GroupInvite]
}

public struct CreateGroupResponse: Codable, Sendable {
    public let id: String
    public let name: String?
    public let createdAt: Date
}

public struct CreateGroupInviteBody: Encodable, Sendable {
    public let chatId: String
    public let inviteType: GroupInviteType
    public let targetUid: Int32?
    public let requiredChatId: String?
    public let expiresAt: Date?

    public init(
        chatId: String, inviteType: GroupInviteType, targetUid: Int32? = nil,
        requiredChatId: String? = nil, expiresAt: Date? = nil
    ) {
        self.chatId = chatId
        self.inviteType = inviteType
        self.targetUid = targetUid
        self.requiredChatId = requiredChatId
        self.expiresAt = expiresAt
    }
}

/// Nil fields are omitted: each editor patches only the field the user saved.
public struct UpdateGroupBody: Encodable, Sendable {
    public let name: String?
    public let description: String?
    public let avatarImageId: String?
    public let membershipMessageVisibility: MembershipMessageVisibility?

    public init(
        name: String? = nil, description: String? = nil, avatarImageId: String? = nil,
        membershipMessageVisibility: MembershipMessageVisibility? = nil
    ) {
        self.name = name
        self.description = description
        self.avatarImageId = avatarImageId
        self.membershipMessageVisibility = membershipMessageVisibility
    }
}

public struct GroupAvatarUpload: Codable, Sendable {
    public let imageId: String
    public let uploadUrl: URL
    public let uploadHeaders: [String: String]
}

public struct SendGroupInviteBody: Encodable, Sendable {
    public let sourceChatId: String
    public let inviteId: String
    public let destinationChatId: String
    public let clientGeneratedId: String

    public init(
        sourceChatId: String, inviteId: String, destinationChatId: String,
        clientGeneratedId: String
    ) {
        self.sourceChatId = sourceChatId
        self.inviteId = inviteId
        self.destinationChatId = destinationChatId
        self.clientGeneratedId = clientGeneratedId
    }
}

public struct SendGroupInviteResponse: Decodable, Sendable {
    public let invite: GroupInvite
    public let message: MessageResponse
}

public protocol GroupAPIClient: Sendable {
    func createGroup(name: String) async throws -> CreateGroupResponse
    func previewGroupInvite(code: String) async throws -> GroupInvitePreview
    func redeemGroupInvite(code: String) async throws -> GroupInfoResponse
    func listGroupInvites(chatID: String) async throws -> GroupInvitesPage
    func createGroupInvite(body: CreateGroupInviteBody) async throws -> GroupInvite
    func revokeGroupInvite(id: String) async throws
    func sendGroupInvite(body: SendGroupInviteBody) async throws -> SendGroupInviteResponse
    func updateGroup(chatID: String, body: UpdateGroupBody) async throws -> GroupInfoResponse
    func groupAvatarUpload(
        chatID: String, filename: String, contentType: String, size: Int64,
        width: Int, height: Int
    ) async throws -> GroupAvatarUpload
}

// Existing injectable clients must opt into real operations, not silently simulate them.
extension GroupAPIClient {
    public func createGroup(name: String) async throws -> CreateGroupResponse {
        throw APIError.unavailable
    }
    public func previewGroupInvite(code: String) async throws -> GroupInvitePreview {
        throw APIError.unavailable
    }
    public func redeemGroupInvite(code: String) async throws -> GroupInfoResponse {
        throw APIError.unavailable
    }
    public func listGroupInvites(chatID: String) async throws -> GroupInvitesPage {
        throw APIError.unavailable
    }
    public func createGroupInvite(body: CreateGroupInviteBody) async throws -> GroupInvite {
        throw APIError.unavailable
    }
    public func revokeGroupInvite(id: String) async throws { throw APIError.unavailable }
    public func sendGroupInvite(body: SendGroupInviteBody) async throws -> SendGroupInviteResponse {
        throw APIError.unavailable
    }
    public func updateGroup(chatID: String, body: UpdateGroupBody) async throws -> GroupInfoResponse
    { throw APIError.unavailable }
    public func groupAvatarUpload(
        chatID: String, filename: String, contentType: String, size: Int64,
        width: Int, height: Int
    ) async throws -> GroupAvatarUpload { throw APIError.unavailable }
}

private struct CreateGroupBody: Encodable { let name: String }
private struct RedeemGroupInviteBody: Encodable { let code: String }
private struct RedeemGroupInviteResponse: Decodable { let chat: GroupInfoResponse }
private struct GroupAvatarUploadBody: Encodable {
    let filename: String
    let contentType: String
    let size: Int64
    let width: Int
    let height: Int
}

extension ChahuaClient {
    public func createGroup(name: String) async throws -> CreateGroupResponse {
        try await send(
            HTTPRequestSpec.json(.post, ["group"], body: CreateGroupBody(name: name)),
            decoding: CreateGroupResponse.self)
    }
    public func previewGroupInvite(code: String) async throws -> GroupInvitePreview {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["invites", "invite"],
                query: [URLQueryItem(name: "inviteCode", value: code)]),
            decoding: GroupInvitePreview.self)
    }
    public func redeemGroupInvite(code: String) async throws -> GroupInfoResponse {
        let response = try await send(
            HTTPRequestSpec.json(
                .post, ["invites", "redeem"], body: RedeemGroupInviteBody(code: code)),
            decoding: RedeemGroupInviteResponse.self)
        return response.chat
    }
    public func listGroupInvites(chatID: String) async throws -> GroupInvitesPage {
        let query = [
            URLQueryItem(name: "groupId", value: chatID), URLQueryItem(name: "limit", value: "100"),
        ]
        return try await send(
            HTTPRequestSpec(method: .get, path: ["invites"], query: query),
            decoding: GroupInvitesPage.self)
    }
    public func createGroupInvite(body: CreateGroupInviteBody) async throws -> GroupInvite {
        try await send(
            HTTPRequestSpec.json(.post, ["invites"], body: body), decoding: GroupInvite.self)
    }
    public func revokeGroupInvite(id: String) async throws {
        try await send(HTTPRequestSpec(method: .delete, path: ["invites", "invite", id]))
    }
    public func sendGroupInvite(body: SendGroupInviteBody) async throws -> SendGroupInviteResponse {
        try await send(
            HTTPRequestSpec.json(.post, ["invites", "send"], body: body),
            decoding: SendGroupInviteResponse.self)
    }
    public func updateGroup(chatID: String, body: UpdateGroupBody) async throws -> GroupInfoResponse
    {
        try await send(
            HTTPRequestSpec.json(.patch, ["group", chatID], body: body),
            decoding: GroupInfoResponse.self)
    }
    public func groupAvatarUpload(
        chatID: String, filename: String, contentType: String, size: Int64,
        width: Int, height: Int
    ) async throws -> GroupAvatarUpload {
        try await send(
            HTTPRequestSpec.json(
                .post, ["group", chatID, "avatar", "upload-url"],
                body: GroupAvatarUploadBody(
                    filename: filename, contentType: contentType, size: size, width: width,
                    height: height)), decoding: GroupAvatarUpload.self)
    }
}
