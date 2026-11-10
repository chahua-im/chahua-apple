import Foundation

private struct AcknowledgeReactionsBody: Encodable {
    let threadId: MessageID?
    let readThrough: String?
}

extension ChahuaClient {
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

    public func unreadReactions(chatID: String, threadID: MessageID?, after: String?) async throws
        -> UnreadReactionIDsResponse
    {
        var query = activityQuery(threadID: threadID)
        if let after {
            query.append(URLQueryItem(name: "after", value: after))
        }
        return try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "reactions"],
                query: query),
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
