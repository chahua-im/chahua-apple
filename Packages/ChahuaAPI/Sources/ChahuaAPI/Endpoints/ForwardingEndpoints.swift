import Foundation

extension ChahuaClient {
    public func listSavedMessages(before: String? = nil, limit: Int = 50)
        async throws -> ListSavedMessagesResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["saved-messages"],
                query: savedMessagesQuery(before: before, limit: limit)),
            decoding: ListSavedMessagesResponse.self)
    }

    public func listChatSavedMessages(chatID: String, before: String? = nil, limit: Int = 50)
        async throws -> ListSavedMessagesResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "saved-messages"],
                query: savedMessagesQuery(before: before, limit: limit)),
            decoding: ListSavedMessagesResponse.self)
    }

    public func saveMessage(messageID: MessageID) async throws -> SavedMessageResponse {
        try await send(
            HTTPRequestSpec(method: .put, path: ["saved-messages", messageID.description]),
            decoding: SavedMessageResponse.self)
    }

    public func removeSavedMessage(savedMessageID: String) async throws {
        try await send(
            HTTPRequestSpec(method: .delete, path: ["saved-messages", "by-id", savedMessageID]))
    }

    public func removeSavedMessage(originalMessageID: MessageID) async throws {
        try await send(
            HTTPRequestSpec(
                method: .delete,
                path: ["saved-messages", "by-message", originalMessageID.description]))
    }

    private func savedMessagesQuery(before: String?, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "limit", value: String(limit)),
            before.map { URLQueryItem(name: "before", value: $0) },
        ].compactMap { $0 }
    }

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
