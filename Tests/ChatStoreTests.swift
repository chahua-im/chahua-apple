import Foundation
import XCTest
@testable import chahua_apple
import ChahuaAPI

@MainActor
final class ChatStoreTests: XCTestCase {
    func testLoadActiveChatsPreservesServerOrder() async {
        let api = FakeChatAPI(chatResults: [.success(ListChatsResponse(chats: [chat(id: "2"), chat(id: "1")]))])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})

        await store.loadActiveChats()

        XCTAssertEqual(store.state.chatListLoadPhase, .loaded)
        XCTAssertEqual(store.state.chats.map(\.id), ["2", "1"])
        let recordedQueries = await api.recordedChatQueries()
        XCTAssertEqual(recordedQueries, [ListChatsQuery(archived: false)])
    }

    func testLoadFailureCanRetry() async {
        let api = FakeChatAPI(chatResults: [.failure(FakeChatAPIError.failed), .success(ListChatsResponse(chats: []))])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})

        await store.loadActiveChats()
        XCTAssertEqual(store.state.chatListLoadPhase, .failed)

        await store.loadActiveChats()
        XCTAssertEqual(store.state.chatListLoadPhase, .loaded)
        XCTAssertTrue(store.state.chats.isEmpty)
    }

    func testInvalidTokenEndsSession() async {
        let api = FakeChatAPI(chatResults: [.failure(APIError.invalidToken)])
        var invalidTokenCalls = 0
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: { invalidTokenCalls += 1 })

        await store.loadActiveChats()

        XCTAssertEqual(store.state.chatListLoadPhase, .failed)
        XCTAssertEqual(invalidTokenCalls, 1)
    }


    func testResetClearsStateAndIgnoresPriorRequest() async {
        let api = FakeChatAPI(suspendChatRequests: true)
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})

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
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
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
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        await store.loadActiveChats()
        await store.refreshActiveChats()
        XCTAssertEqual(store.state.chats.map(\.id), ["original"])
        XCTAssertTrue(store.state.chatListRefreshFailed)
    }

    func testEventDuringRefreshRequiresTrailingSnapshot() async throws {
        let api = FakeChatAPI(suspendChatRequests: true)
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let load = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        let event = try JSONDecoder().decode(
            RealtimeServerEvent.self,
            from: Data(#"{"type":"chatArchiveStateChanged","payload":{"chatId":"1","archived":true}}"#.utf8)
        )
        await store.applyRealtimeEvent(event, currentUserID: 1)
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "old")])))
        await api.waitForChatRequest()
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "new")])))
        await load.value
        XCTAssertEqual(store.state.chats.map(\.id), ["new"])
    }

    func testOldSessionErrorCannotExpireReplacementSession() async {
        let api = FakeChatAPI(suspendChatRequests: true)
        var expired = false
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: { expired = true })
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
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
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

    func testDraftSubmissionIsDurableAndSharedAcrossStoreRestoration() async throws {
        let api = FakeChatAPI()
        let queue = testOutgoingQueue(apiClient: api)
        let store = ChatStore(apiClient: api, outgoingQueue: queue, onInvalidToken: {})
        await queue.activate(uid: 1)
        store.drafts.setDraftText("  hello\n世界  ", chatID: "chat")
        await store.drafts.flushDraft(chatID: "chat")
        let submitted = await store.drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(submitted)
        XCTAssertEqual(store.drafts.draftText(chatID: "chat"), "")
        XCTAssertEqual(queue.pendingMessages(chatID: "chat").map(\.text), ["hello\n世界"])
        store.drafts.setDraftText("unsent draft", chatID: "other")
        await store.drafts.flushDraft(chatID: "other")
        await queue.deactivate()
        store.reset()
        await queue.activate(uid: 1)
        XCTAssertEqual(store.drafts.draftText(chatID: "other"), "unsent draft")
        XCTAssertEqual(store.drafts.draftText(chatID: "chat"), "")
        let entries = store.conversationMessages.projection(for: "chat", remoteMessages: [], includePendingOutgoing: true).entries
        XCTAssertEqual(entries.count, 1)
        await queue.deactivate()
    }

    func testTypingBeforeStorageRestorationIsNotOverwritten() async throws {
        let api = FakeChatAPI()
        let queue = testOutgoingQueue(apiClient: api)
        let store = ChatStore(apiClient: api, outgoingQueue: queue, onInvalidToken: {})
        await queue.activate(uid: 1)
        try await queue.saveDraft(chatID: "chat", text: "old persisted", editRevision: 20, updatedAt: Date())
        await queue.deactivate()
        store.reset()
        store.drafts.setDraftText("new typing", chatID: "chat")
        await queue.activate(uid: 1)
        XCTAssertEqual(store.drafts.draftText(chatID: "chat"), "new typing")
        await store.drafts.flushDraft(chatID: "chat")
        await queue.deactivate()
        store.reset()
        await queue.activate(uid: 1)
        XCTAssertEqual(store.drafts.draftText(chatID: "chat"), "new typing")
        await queue.deactivate()
    }

    func testCompositionCancelsDebouncedSaveAndResumesWhenCommittedTextIsUnchanged() async throws {
        let h = try await openDraftHarness()
        h.store.drafts.setDraftText("already committed", chatID: "chat")
        await Task.yield()
        h.store.drafts.setDraftComposing(true, chatID: "chat")

        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(h.probe.draftWriteAttempts, 0)
        let duringComposition = try await h.localStore.restore()
        XCTAssertTrue(duringComposition.isEmpty)

        h.store.drafts.setDraftText("already committed", chatID: "chat")
        h.store.drafts.setDraftComposing(false, chatID: "chat")
        try await waitForPersistedDraft("already committed", in: h)
    }

    func testCompositionDefersExplicitBackgroundAndRetryFlushesAndRefusesSubmission() async throws {
        let h = try await openDraftHarness()
        h.store.drafts.setDraftText("last persisted", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.probe.draftWriteAttempts = 0
        h.probe.failDraftWrites = true
        h.store.drafts.setDraftComposing(true, chatID: "chat")
        h.store.drafts.setDraftText("final committed text", chatID: "chat")

        await h.store.drafts.flushDraft(chatID: "chat")
        await h.store.retryLocalStorage()
        h.store.setForegroundActive(false)
        let submitted = await h.store.drafts.submitDraft(chatID: "chat")
        try await Task.sleep(for: .milliseconds(650))

        XCTAssertFalse(submitted)
        XCTAssertEqual(h.probe.draftWriteAttempts, 0)
        XCTAssertEqual(h.probe.enqueueAttempts, 0)
        XCTAssertFalse(h.store.drafts.draftSaveFailed)
        XCTAssertEqual(h.queue.storageState, .ready)
        let duringComposition = try await h.localStore.restore()
        XCTAssertEqual(duringComposition.first?.draft.text, "last persisted")
        XCTAssertTrue(duringComposition.flatMap(\.outgoing).isEmpty)

        h.probe.failDraftWrites = false
        h.store.drafts.setDraftComposing(false, chatID: "chat")
        try await waitForPersistedDraft("final committed text", in: h)
    }

    func testCompositionCommitAutosavesFinalTextWithoutExplicitFlush() async throws {
        let h = try await openDraftHarness()
        h.store.drafts.setDraftText("previous", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.probe.draftWriteAttempts = 0
        h.store.drafts.setDraftComposing(true, chatID: "chat")
        h.store.drafts.setDraftText("你好，世界", chatID: "chat")

        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(h.probe.draftWriteAttempts, 0)
        let duringComposition = try await h.localStore.restore()
        XCTAssertEqual(duringComposition.first?.draft.text, "previous")

        h.store.drafts.setDraftComposing(false, chatID: "chat")
        try await waitForPersistedDraft("你好，世界", in: h)
    }

    func testResetClearsCompositionAndCancelsDeferredSaveAcrossSessionRestoration() async throws {
        let h = try await openDraftHarness()
        h.store.drafts.setDraftComposing(true, chatID: "chat")
        h.store.drafts.setDraftText("discarded session", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.store.drafts.setDraftComposing(false, chatID: "chat")
        h.store.reset()
        await h.queue.deactivate()
        await h.queue.activate(uid: 1)
        XCTAssertEqual(h.probe.draftWriteAttempts, 0)

        h.store.drafts.setDraftComposing(true, chatID: "chat")
        h.store.drafts.setDraftText("another discarded session", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.store.reset()
        h.store.drafts.setDraftText("replacement session", chatID: "chat")
        try await waitForPersistedDraft("replacement session", in: h)

        let submitted = await h.store.drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(submitted)
        let persisted = try await h.localStore.restore()
        XCTAssertEqual(persisted.first?.draft.text, "")
        XCTAssertEqual(persisted.flatMap(\.outgoing).map(\.text), ["replacement session"])
    }

    func testFailedLocalEnqueueKeepsDraftAndRetryEnqueuesExactlyOnce() async throws {
        let h = try await openDraftHarness()
        h.store.drafts.setDraftText("keep this", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.probe.failEnqueue = true
        let failed = await h.store.drafts.submitDraft(chatID: "chat")
        XCTAssertFalse(failed)
        XCTAssertEqual(h.store.drafts.draftText(chatID: "chat"), "keep this")
        XCTAssertTrue(h.store.drafts.draftSaveFailed)
        XCTAssertFalse(h.store.drafts.committingDrafts.contains("chat"))
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        let afterFailure = try await h.localStore.restore()
        XCTAssertEqual(afterFailure.first?.draft.text, "keep this")
        XCTAssertTrue(afterFailure.flatMap(\.outgoing).isEmpty)

        h.probe.failEnqueue = false
        await h.store.retryLocalStorage()
        let retried = await h.store.drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(retried)
        XCTAssertEqual(h.store.drafts.draftText(chatID: "chat"), "")
        XCTAssertFalse(h.store.drafts.draftSaveFailed)
        let afterRetry = try await h.localStore.restore()
        XCTAssertEqual(afterRetry.flatMap(\.outgoing).map(\.text), ["keep this"])
    }

    private func openDraftHarness() async throws -> DraftHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatDraft-\(UUID().uuidString)")
        let localStore = try await Task.detached { try ChahuaLocalStore(directory: root) }.value
        let api = FakeChatAPI()
        let probe = DraftStorageProbe()
        let queue = OutgoingMessageQueue(
            apiClient: api,
            localStoreFactory: { _ in localStore },
            onInvalidToken: {},
            beforeStorageOperation: { operation in try probe.check(operation) }
        )
        let store = ChatStore(apiClient: api, outgoingQueue: queue, onInvalidToken: {})
        addTeardownBlock {
            await MainActor.run { store.reset() }
            await queue.deactivate()
            try FileManager.default.removeItem(at: root)
        }
        await queue.activate(uid: 1)
        return DraftHarness(store: store, queue: queue, localStore: localStore, probe: probe)
    }

    private func waitForPersistedDraft(
        _ text: String, in harness: DraftHarness, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while harness.queue.snapshots["chat"]?.draft.text != text {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out awaiting persisted draft", file: file, line: line)
                throw DraftStorageProbe.Failure.timeout
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let persisted = try await harness.localStore.restore()
        XCTAssertEqual(persisted.first { $0.chatID == "chat" }?.draft.text, text, file: file, line: line)
    }

    func testHistoryIngressAcknowledgesDurablePendingBeforeReturningSnapshot() async throws {
        let api = FakeChatAPI()
        let queue = testOutgoingQueue(apiClient: api)
        let store = ChatStore(apiClient: api, outgoingQueue: queue, onInvalidToken: {})
        await queue.activate(uid: 1)
        store.drafts.setDraftText("delivered before response", chatID: "chat")
        let submitted = await store.drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(submitted)
        let pending = try XCTUnwrap(queue.pendingMessages(chatID: "chat").first)
        let remote = try TimelineTestFixtures.message(id: "remote", at: 1, text: pending.text, clientGeneratedID: pending.clientGeneratedID)
        await api.appendMessageResult(chatID: "chat", page: try TimelineTestFixtures.page([remote]))
        let page = try await store.fetchMessages(chatID: "chat")
        XCTAssertTrue(queue.pendingMessages(chatID: "chat").isEmpty)
        let projection = store.conversationMessages.projection(for: "chat", remoteMessages: page.messages, includePendingOutgoing: true)
        XCTAssertEqual(projection.entries.map(\.stableKey), [.clientGenerated(pending.clientGeneratedID)])
        await queue.deactivate()
        store.reset()
        await queue.activate(uid: 1)
        XCTAssertTrue(queue.pendingMessages(chatID: "chat").isEmpty)
        await queue.deactivate()
    }
}

private enum FakeChatAPIError: Error { case failed }

@MainActor
private struct DraftHarness {
    let store: ChatStore
    let queue: OutgoingMessageQueue
    let localStore: ChahuaLocalStore
    let probe: DraftStorageProbe
}

@MainActor
private final class DraftStorageProbe {
    enum Failure: Error { case storage, timeout }
    var draftWriteAttempts = 0
    var enqueueAttempts = 0
    var failDraftWrites = false
    var failEnqueue = false

    func check(_ operation: OutgoingMessageQueue.StorageOperation) throws {
        if operation == .enqueue {
            enqueueAttempts += 1
            if failEnqueue { throw Failure.storage }
        }
        if operation == .saveDraft {
            draftWriteAttempts += 1
            if failDraftWrites { throw Failure.storage }
        }
    }
}

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

    func appendMessageResult(chatID: String, page: ListMessagesResponse) {
        messageResults[chatID, default: []].append(.success(page))
    }

    func authenticate(candidateJWT: String) async throws -> MeResponse { throw APIError.unavailable }
    func createDevSession(uid: Int32, clientID: String) async throws -> String { throw APIError.unavailable }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func groupInfo(chatID: String) async throws -> GroupInfoResponse { throw APIError.unavailable }
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse { throw APIError.unavailable }
    func getMessage(chatID: String, messageID: String) async throws -> MessageResponse { throw APIError.unavailable }
    func putReaction(chatID: String, messageID: String, emoji: String) async throws { throw APIError.unavailable }
    func deleteReaction(chatID: String, messageID: String, emoji: String) async throws { throw APIError.unavailable }

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
