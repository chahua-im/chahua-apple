import Foundation

public struct ListMessagesQuery: Sendable, Equatable {
    public var before: String?
    public var around: String?
    public var after: String?
    public var max: Int64?
    public var threadID: String?

    public init(
        before: String? = nil,
        around: String? = nil,
        after: String? = nil,
        max: Int64? = nil,
        threadID: String? = nil
    ) {
        self.before = before
        self.around = around
        self.after = after
        self.max = max
        self.threadID = threadID
    }

    var queryItems: [URLQueryItem] {
        [
            before.map { URLQueryItem(name: "before", value: $0) },
            around.map { URLQueryItem(name: "around", value: $0) },
            after.map { URLQueryItem(name: "after", value: $0) },
            max.map { URLQueryItem(name: "max", value: String($0)) },
            threadID.map { URLQueryItem(name: "thread_id", value: $0) },
        ].compactMap { $0 }
    }
}

public extension ChahuaClient {
    func listMessages(
        chatID: Int64,
        query: ListMessagesQuery = .init()
    ) async throws -> ListMessagesResponse {
        try await send(
            HTTPRequestSpec(
                method: .get,
                path: "/chats/\(chatID)/messages",
                query: query.queryItems
            ),
            decoding: ListMessagesResponse.self
        )
    }

    func sendMessage(
        chatID: Int64,
        body: CreateMessageBody
    ) async throws -> MessageResponse {
        try await send(
            HTTPRequestSpec.json(.post, "/chats/\(chatID)/messages", body: body),
            decoding: MessageResponse.self
        )
    }
}
