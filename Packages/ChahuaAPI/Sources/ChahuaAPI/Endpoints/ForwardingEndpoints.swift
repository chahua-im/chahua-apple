import Foundation

extension ChahuaClient {
    public func forwardMessage(chatID: String, messageID: MessageID, body: ForwardMessageBody)
        async throws -> MessageResponse
    {
        try await send(
            HTTPRequestSpec.json(
                .post, ["chats", chatID, "messages", messageID.description, "forward"], body: body),
            decoding: MessageResponse.self)
    }

    public func forwardMessages(chatID: String, body: ForwardMessagesBody)
        async throws -> MessageResponse
    {
        try await send(
            HTTPRequestSpec.json(.post, ["chats", chatID, "messages", "forward"], body: body),
            decoding: MessageResponse.self)
    }

    public func getForwardedMessages(
        chatID: String, messageID: MessageID, bundleID: String? = nil
    ) async throws -> ForwardedMessagesResponse {
        let root = ["chats", chatID, "messages", messageID.description]
        let suffix =
            bundleID.map { ["forwarded-bundles", $0, "messages"] } ?? ["forwarded-messages"]
        return try await send(
            HTTPRequestSpec(method: .get, path: root + suffix),
            decoding: ForwardedMessagesResponse.self)
    }

    public func getSavedForwardedMessages(savedMessageID: String, bundleID: String? = nil)
        async throws -> ForwardedMessagesResponse
    {
        let suffix =
            bundleID.map { ["forwarded-bundles", $0, "messages"] } ?? ["forwarded-messages"]
        return try await send(
            HTTPRequestSpec(method: .get, path: ["saved-messages", savedMessageID] + suffix),
            decoding: ForwardedMessagesResponse.self)
    }
}
