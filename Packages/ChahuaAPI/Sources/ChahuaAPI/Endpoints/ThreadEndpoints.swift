import Foundation

/// Root-ID ordering for the chat-wide thread directory, independent of subscriptions.
public enum ThreadOrder: String, Codable, Sendable {
    case newest
    case oldest
}

public struct ListChatThreadsQuery: Sendable, Equatable {
    public var limit: Int?
    public var cursor: MessageID?
    public var order: ThreadOrder?

    public init(limit: Int? = nil, cursor: MessageID? = nil, order: ThreadOrder? = nil) {
        self.limit = limit
        self.cursor = cursor
        self.order = order
    }

    var queryItems: [URLQueryItem] {
        [
            limit.map { URLQueryItem(name: "limit", value: String($0)) },
            cursor.map { URLQueryItem(name: "cursor", value: $0.description) },
            order.map { URLQueryItem(name: "order", value: $0.rawValue) },
        ].compactMap { $0 }
    }
}

/// A root-message page; retain the same order when passing the exclusive cursor.
public struct ListChatThreadsResponse: Codable, Hashable, Sendable {
    public let threads: [MessageResponse]
    public let nextCursor: MessageID?

    public init(threads: [MessageResponse], nextCursor: MessageID? = nil) {
        self.threads = threads
        self.nextCursor = nextCursor
    }
}

public struct ListThreadParticipantsQuery: Sendable, Equatable {
    public var limit: Int?
    public var cursor: Int32?

    public init(limit: Int? = nil, cursor: Int32? = nil) {
        self.limit = limit
        self.cursor = cursor
    }

    var queryItems: [URLQueryItem] {
        [
            limit.map { URLQueryItem(name: "limit", value: String($0)) },
            cursor.map { URLQueryItem(name: "cursor", value: String($0)) },
        ].compactMap { $0 }
    }
}

/// Root and surviving published reply authors, sorted by UID, not subscribers.
public struct ListThreadParticipantsResponse: Codable, Hashable, Sendable {
    public let participants: [User]
    public let nextCursor: Int32?

    public init(participants: [User], nextCursor: Int32? = nil) {
        self.participants = participants
        self.nextCursor = nextCursor
    }
}

/// Query fields accepted by `GET /threads` for the current user's subscriptions.
///
/// Set `archived` to `false` for active threads. Pass the response's opaque
/// `nextCursor` as `before` to fetch a later page without changing server ordering.
public struct ListThreadsQuery: Sendable, Equatable {
    public var limit: Int?
    public var before: String?
    public var archived: Bool?
    /// Restricts the page to one subscribed root while retaining the archive filter.
    public var rootId: MessageID?

    public init(
        limit: Int? = nil, before: String? = nil, archived: Bool? = nil,
        rootId: MessageID? = nil
    ) {
        self.limit = limit
        self.before = before
        self.archived = archived
        self.rootId = rootId
    }

    var queryItems: [URLQueryItem] {
        [
            limit.map { URLQueryItem(name: "limit", value: String($0)) },
            before.map { URLQueryItem(name: "before", value: $0) },
            archived.map { URLQueryItem(name: "archived", value: String($0)) },
            rootId.map { URLQueryItem(name: "rootId", value: $0.description) },
        ].compactMap { $0 }
    }
}

/// The current user's subscription to one thread, from `GET .../subscribe`.
///
/// Only subscribed threads appear in `GET /threads`; `archived` selects which list.
/// A thread the user never subscribed to reports `false` for both fields.
public struct ThreadSubscriptionStatus: Codable, Hashable, Sendable {
    public let subscribed: Bool
    public let archived: Bool

    public init(subscribed: Bool, archived: Bool) {
        self.subscribed = subscribed
        self.archived = archived
    }
}

extension ChahuaClient {
    public func listChatThreads(chatID: String, query: ListChatThreadsQuery) async throws
        -> ListChatThreadsResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "threads"], query: query.queryItems),
            decoding: ListChatThreadsResponse.self
        )
    }

    public func listThreadParticipants(
        chatID: String, threadID: String, query: ListThreadParticipantsQuery
    ) async throws -> ListThreadParticipantsResponse {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "threads", threadID, "participants"],
                query: query.queryItems),
            decoding: ListThreadParticipantsResponse.self
        )
    }

    public func threadReadState(chatID: String, threadID: String) async throws -> ReadStateResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "threads", threadID, "read-state"]),
            decoding: ReadStateResponse.self
        )
    }

    public func archiveThread(chatID: String, threadID: String) async throws {
        try await send(
            HTTPRequestSpec(method: .put, path: ["chats", chatID, "threads", threadID, "archive"]))
    }

    public func unarchiveThread(chatID: String, threadID: String) async throws {
        try await send(
            HTTPRequestSpec(
                method: .delete, path: ["chats", chatID, "threads", threadID, "archive"]))
    }

    public func threadSubscriptionStatus(chatID: String, threadID: String) async throws
        -> ThreadSubscriptionStatus
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "threads", threadID, "subscribe"]),
            decoding: ThreadSubscriptionStatus.self
        )
    }

    public func subscribeThread(chatID: String, threadID: String) async throws {
        try await send(
            HTTPRequestSpec(
                method: .put, path: ["chats", chatID, "threads", threadID, "subscribe"]))
    }

    public func markThreadRead(chatID: String, threadID: String, messageID: MessageID)
        async throws
        -> ReadStateResponse
    {
        try await send(
            HTTPRequestSpec.json(
                .post, ["chats", chatID, "threads", threadID, "read"],
                body: MarkReadBody(messageId: messageID)),
            decoding: ReadStateResponse.self
        )
    }

    /// Fetches one subscribed thread page with authenticated `GET /threads`.
    public func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["threads"], query: query.queryItems),
            decoding: ListThreadsResponse.self
        )
    }

    /// Sends a reply with JSON `POST /chats/{chatID}/threads/{threadID}/messages`.
    public func sendThreadMessage(
        chatID: String,
        threadID: String,
        body: CreateMessageBody
    ) async throws -> MessageResponse {
        try await send(
            HTTPRequestSpec.json(
                .post, ["chats", chatID, "threads", threadID, "messages"], body: body),
            decoding: MessageResponse.self
        )
    }
}
