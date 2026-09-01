import Foundation
import XCTest
@testable import chahua_apple
import ChahuaAPI

@MainActor
final class ChatStoreTests: XCTestCase {
    func testLoadActiveChatsPreservesServerOrder() async {
        let api = FakeChatAPI(chatResults: [.success(ListChatsResponse(chats: [chat(id: "2"), chat(id: "1")]))])
        let store = ChatStore(apiClient: api, onInvalidToken: {})

        await store.loadActiveChats()

        XCTAssertEqual(store.state.chatListLoadPhase, .loaded)
        XCTAssertEqual(store.state.chats.map(\.id), ["2", "1"])
        let recordedQueries = await api.recordedChatQueries()
        XCTAssertEqual(recordedQueries, [ListChatsQuery(archived: false)])
    }

    func testLoadFailureCanRetry() async {
        let api = FakeChatAPI(chatResults: [.failure(FakeChatAPIError.failed), .success(ListChatsResponse(chats: []))])
        let store = ChatStore(apiClient: api, onInvalidToken: {})

        await store.loadActiveChats()
        XCTAssertEqual(store.state.chatListLoadPhase, .failed)

        await store.loadActiveChats()
        XCTAssertEqual(store.state.chatListLoadPhase, .loaded)
        XCTAssertTrue(store.state.chats.isEmpty)
    }

    func testInvalidTokenEndsSession() async {
        let api = FakeChatAPI(chatResults: [.failure(APIError.invalidToken)])
        var invalidTokenCalls = 0
        let store = ChatStore(apiClient: api, onInvalidToken: { invalidTokenCalls += 1 })

        await store.loadActiveChats()

        XCTAssertEqual(store.state.chatListLoadPhase, .failed)
        XCTAssertEqual(invalidTokenCalls, 1)
    }

    func testFetchedMessagesAreScopedAndUpserted() async throws {
        let original = try message(id: "a", chatID: "1", text: "original")
        let replacement = try message(id: "a", chatID: "1", text: "replacement")
        let other = try message(id: "b", chatID: "2", text: "other")
        let api = FakeChatAPI(messageResults: [
            "1": [.success(try listResponse(messages: [original])), .success(try listResponse(messages: [replacement]))],
            "2": [.success(try listResponse(messages: [other]))],
        ])
        let store = ChatStore(apiClient: api, onInvalidToken: {})

        _ = try await store.fetchMessages(chatID: "1")
        _ = try await store.fetchMessages(chatID: "2")
        _ = try await store.fetchMessages(chatID: "1")

        XCTAssertEqual(store.state.messagesByChatID["1"]?.count, 1)
        XCTAssertEqual(store.state.messagesByChatID["1"]?["a"]?.message, "replacement")
        XCTAssertEqual(store.state.messagesByChatID["2"]?["b"]?.message, "other")
    }

    func testResetClearsStateAndIgnoresPriorRequest() async {
        let api = FakeChatAPI(suspendChatRequests: true)
        let store = ChatStore(apiClient: api, onInvalidToken: {})

        let loadTask = Task { await store.loadActiveChats() }
        await api.waitForChatRequest()
        store.reset()
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "stale")])))
        await loadTask.value

        XCTAssertEqual(store.state.chatListLoadPhase, .idle)
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertTrue(store.state.messagesByChatID.isEmpty)
    }

    private func chat(id: String) -> ChatListItem {
        ChatListItem(id: id, name: "Chat \(id)", unreadCount: 0, archived: false, kind: .group)
    }

    private func message(id: String, chatID: String, text: String) throws -> MessageResponse {
        let data = Data(#"""
        {
          "id": "\#(id)", "chatId": "\#(chatID)", "clientGeneratedId": "client-\#(id)", "messageType": "text",
          "sender": {"uid": 1, "gender": 0, "name": "Ada", "avatarUrl": null, "userGroup": null},
          "createdAt": "2026-08-31T12:34:56Z", "isEdited": false, "isDeleted": false,
          "hasAttachments": false, "attachments": [], "reactions": [], "mentions": [], "message": "\#(text)"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MessageResponse.self, from: data)
    }

    private func listResponse(messages: [MessageResponse]) throws -> ListMessagesResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let messagesJSON = try String(decoding: encoder.encode(messages), as: UTF8.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            ListMessagesResponse.self,
            from: Data("{\"messages\":\(messagesJSON)}".utf8)
        )
    }
}

private enum FakeChatAPIError: Error { case failed }

private actor FakeChatAPI: ChahuaAPIClient {
    var chatQueries: [ListChatsQuery] = []
    private var chatResults: [Result<ListChatsResponse, Error>]
    private var messageResults: [String: [Result<ListMessagesResponse, Error>]]
    private let suspendChatRequests: Bool
    private var pendingChatRequest: CheckedContinuation<ListChatsResponse, Error>?
    private var chatRequestObserver: CheckedContinuation<Void, Never>?

    init(
        chatResults: [Result<ListChatsResponse, Error>] = [],
        messageResults: [String: [Result<ListMessagesResponse, Error>]] = [:],
        suspendChatRequests: Bool = false
    ) {
        self.chatResults = chatResults
        self.messageResults = messageResults
        self.suspendChatRequests = suspendChatRequests
    }

    func authenticate(candidateJWT: String) async throws -> MeResponse { throw APIError.unavailable }
    func createDevSession(uid: Int32, clientID: String) async throws -> String { throw APIError.unavailable }
    func me() async throws -> MeResponse { throw APIError.unavailable }

    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse {
        chatQueries.append(query)
        if suspendChatRequests {
            chatRequestObserver?.resume()
            chatRequestObserver = nil
            return try await withCheckedThrowingContinuation { pendingChatRequest = $0 }
        }

        return try chatResults.removeFirst().get()
    }

    func recordedChatQueries() -> [ListChatsQuery] { chatQueries }

    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        guard var results = messageResults[chatID], !results.isEmpty else { throw APIError.unavailable }
        let result = results.removeFirst()
        messageResults[chatID] = results
        return try result.get()
    }

    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse { throw APIError.unavailable }

    func waitForChatRequest() async {
        if pendingChatRequest != nil { return }
        await withCheckedContinuation { chatRequestObserver = $0 }
    }

    func resumeChatRequest(with result: Result<ListChatsResponse, Error>) {
        switch result {
        case .success(let response): pendingChatRequest?.resume(returning: response)
        case .failure(let error): pendingChatRequest?.resume(throwing: error)
        }
        pendingChatRequest = nil
    }
}
