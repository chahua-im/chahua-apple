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
    }

    private func chat(id: String) -> ChatListItem {
        ChatListItem(id: id, name: "Chat \(id)", unreadCount: 0, archived: false, kind: .group)
    }

    func testRefreshReplacesLoadedAndEmptyListsAndRetainsRowsOnFailure() async {
        let api = FakeChatAPI(chatResults: [
            .success(ListChatsResponse(chats: [])),
            .success(ListChatsResponse(chats: [chat(id: "2")], nextCursor: "next")),
            .success(ListChatsResponse(chats: [chat(id: "2"), chat(id: "1")])),
            .failure(FakeChatAPIError.failed),
        ])
        let store = ChatStore(apiClient: api, onInvalidToken: {})
        await store.loadActiveChats()
        await store.refreshActiveChats()
        XCTAssertEqual(store.state.chats.map(\.id), ["2", "1"])
        await store.refreshActiveChats()
        XCTAssertEqual(store.state.chats.map(\.id), ["2", "1"])
        XCTAssertEqual(store.state.chatListLoadPhase, .loaded)
        XCTAssertTrue(store.state.chatListRefreshFailed)
    }

    func testRepeatedCursorRetainsPreviousSnapshot() async {
        let api = FakeChatAPI(chatResults: [
            .success(ListChatsResponse(chats: [chat(id: "original")])),
            .success(ListChatsResponse(chats: [chat(id: "partial")], nextCursor: "same")),
            .success(ListChatsResponse(chats: [], nextCursor: "same")),
        ])
        let store = ChatStore(apiClient: api, onInvalidToken: {})
        await store.loadActiveChats()
        await store.refreshActiveChats()
        XCTAssertEqual(store.state.chats.map(\.id), ["original"])
        XCTAssertTrue(store.state.chatListRefreshFailed)
    }

    func testEventDuringRefreshRequiresTrailingSnapshot() async throws {
        let api = FakeChatAPI(suspendChatRequests: true)
        let store = ChatStore(apiClient: api, onInvalidToken: {})
        let load = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        let event = try JSONDecoder().decode(
            RealtimeServerEvent.self,
            from: Data(#"{"type":"chatArchiveStateChanged","payload":{"chatId":"1","archived":true}}"#.utf8)
        )
        store.applyRealtimeEvent(event, currentUserID: 1)
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "old")])))
        await api.waitForChatRequest()
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "new")])))
        await load.value
        XCTAssertEqual(store.state.chats.map(\.id), ["new"])
    }

    func testOldSessionErrorCannotExpireReplacementSession() async {
        let api = FakeChatAPI(suspendChatRequests: true)
        var expired = false
        let store = ChatStore(apiClient: api, onInvalidToken: { expired = true })
        let load = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        store.reset()
        await api.resumeChatRequest(with: .failure(APIError.invalidToken))
        await load.value
        XCTAssertFalse(expired)
        XCTAssertEqual(store.state.chatListLoadPhase, .idle)
    }

    func testForegroundRefreshDoesNotReuseCanceledBackgroundSnapshot() async {
        let api = FakeChatAPI(suspendChatRequests: true)
        let store = ChatStore(apiClient: api, onInvalidToken: {})
        let oldRefresh = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        store.cancelRealtimeRecovery()
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "stale")])))
        await oldRefresh.value
        XCTAssertTrue(store.state.chats.isEmpty)
        let foregroundRefresh = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "fresh")])))
        await foregroundRefresh.value
        XCTAssertEqual(store.state.chats.map(\.id), ["fresh"])
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

        guard !chatResults.isEmpty else { throw APIError.unavailable }
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
