import Foundation

extension ChahuaClient {
    public func readReceipt(chatID: String, threadID: MessageID?) async throws
        -> ReadReceiptResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "read-receipt"],
                query: threadID.map { [URLQueryItem(name: "threadId", value: $0.description)] }
                    ?? []),
            decoding: ReadReceiptResponse.self)
    }

    public func readReceiptSettings() async throws -> ReadReceiptSettingsResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["me", "read-receipt-settings"]),
            decoding: ReadReceiptSettingsResponse.self)
    }

    public func updateReadReceiptSettings(visibility: ReadReceiptVisibility) async throws
        -> ReadReceiptSettingsResponse
    {
        try await send(
            HTTPRequestSpec.json(
                .put, ["me", "read-receipt-settings"],
                body: ReadReceiptSettingsResponse(visibility: visibility)),
            decoding: ReadReceiptSettingsResponse.self)
    }

    public func friendReadReceiptSettings(peerUID: Int32) async throws
        -> FriendReadReceiptSettingsResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["friends", String(peerUID), "read-receipt-settings"]),
            decoding: FriendReadReceiptSettingsResponse.self)
    }

    public func updateFriendReadReceiptSettings(
        peerUID: Int32, override: FriendReadReceiptOverride
    ) async throws -> FriendReadReceiptSettingsResponse {
        try await send(
            HTTPRequestSpec.json(
                .put, ["friends", String(peerUID), "read-receipt-settings"],
                body: FriendReadReceiptSettingsResponse(override: override)),
            decoding: FriendReadReceiptSettingsResponse.self)
    }
}
