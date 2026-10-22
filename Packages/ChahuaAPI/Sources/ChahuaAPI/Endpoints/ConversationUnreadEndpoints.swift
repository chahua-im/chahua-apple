import Foundation

private struct AcknowledgeReactionsBody: Encodable {
    let threadId: MessageID?
    let readThrough: String?
}

extension ChahuaClient {
    public func conversationUnreadSummaries(views: [ConversationView]) async throws
        -> ConversationUnreadResponse
    {
        try await send(
            HTTPRequestSpec.json(
                .post, ["conversations", "unread-summary"],
                body: ConversationUnreadRequest(views: views)),
            decoding: ConversationUnreadResponse.self
        )
    }

    public func unreadMentions(chatID: String, threadID: MessageID?) async throws
        -> UnreadMentionIDsResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "mentions"],
                query: activityQuery(threadID: threadID)),
            decoding: UnreadMentionIDsResponse.self
        )
    }

    public func unreadReactions(chatID: String, threadID: MessageID?) async throws
        -> UnreadReactionIDsResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "reactions"],
                query: activityQuery(threadID: threadID)),
            decoding: UnreadReactionIDsResponse.self
        )
    }

    public func acknowledgeReactions(
        chatID: String, threadID: MessageID?, readThrough: String?
    ) async throws -> UnreadReactionsAckResponse {
        try await send(
            HTTPRequestSpec.json(
                .post, ["chats", chatID, "reactions", "read"],
                body: AcknowledgeReactionsBody(threadId: threadID, readThrough: readThrough)),
            decoding: UnreadReactionsAckResponse.self
        )
    }

    private func activityQuery(threadID: MessageID?) -> [URLQueryItem] {
        threadID.map { [URLQueryItem(name: "threadId", value: $0.description)] } ?? []
    }
}
