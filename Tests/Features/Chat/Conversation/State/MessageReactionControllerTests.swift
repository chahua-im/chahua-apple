import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class MessageReactionControllerTests: XCTestCase {
    func testUnknownBroadcastOwnershipUsesAuthoritativeDeleteAndDeduplicatesIntent() async throws {
        let broadcast = try message(reactions: [["emoji": "👍", "count": 6]])
        let mine = try message(reactions: [["emoji": "👍", "count": 6, "reactedByMe": true]])
        let removed = try message(reactions: [["emoji": "👍", "count": 5, "reactedByMe": false]])
        let (controller, api, store) = makeController()
        let timeline = try await timeline(message: broadcast, store: store)
        let operation = Task { await controller.toggle(message: broadcast, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        await controller.toggle(message: broadcast, emoji: "❤️", currentUserID: 1)
        XCTAssertEqual(controller.pendingMessageIDs, [broadcast.id])
        await api.finishRead(0, with: .success(mine))
        await api.waitForRequests(2)
        await api.finishMutation(1, with: .success(()))
        await api.waitForRequests(3)
        await api.finishRead(2, with: .success(removed))
        await operation.value

        let requests = await api.requests()
        XCTAssertEqual(requests, [.get, .delete("👍"), .get])
        XCTAssertEqual(visibleMessage(timeline)?.reactions, removed.reactions)
        XCTAssertTrue(controller.pendingMessageIDs.isEmpty)
        XCTAssertNil(controller.error)
    }

    func testMissingPersonalizationAfterAuthoritativeReadNeverBecomesAnAdd() async throws {
        let unknown = try message(reactions: [["emoji": "👍", "count": 8, "reactors": [["uid": 2]]]])
        let (controller, api, _) = makeController()
        let operation = Task { await controller.toggle(message: unknown, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        await api.finishRead(0, with: .success(unknown))
        await operation.value

        let requests = await api.requests()
        XCTAssertEqual(requests, [.get])
        XCTAssertNotNil(controller.error)
    }

    func testRealtimeBeforeMutationResponseAndDuringReadbackWinsOverLateHTTP() async throws {
        let original = try message()
        let stale = try message(reactions: [["emoji": "👍", "count": 1, "reactedByMe": true]])
        let beforeHTTP = try message(reactions: [["emoji": "👍", "count": 2]])
        let duringRead = try message(reactions: [["emoji": "👍", "count": 3]])
        let afterHTTP = try message(reactions: [["emoji": "👍", "count": 4]])
        let (controller, api, store) = makeController()
        let timeline = try await timeline(message: original, store: store)
        let operation = Task { await controller.toggle(message: original, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        await api.finishRead(0, with: .success(original))
        await api.waitForRequests(2)
        store.apply(reactionEvent(beforeHTTP))
        await api.finishMutation(1, with: .success(()))
        await api.waitForRequests(3)
        store.apply(reactionEvent(duringRead))
        await api.finishRead(2, with: .success(stale))
        await operation.value

        XCTAssertEqual(visibleMessage(timeline)?.reactions, duringRead.reactions)
        store.apply(reactionEvent(afterHTTP))
        XCTAssertEqual(visibleMessage(timeline)?.reactions, afterHTTP.reactions)
        XCTAssertNil(controller.error)
    }

    func testOwnBroadcastDuringMutationDoesNotPreventAuthoritativeOwnershipHydration() async throws {
        let original = try message(reactions: [["emoji": "👍", "count": 5, "reactedByMe": false]])
        let broadcast = try message(reactions: [["emoji": "👍", "count": 6, "reactors": [["uid": 2]]]])
        let personalized = try message(reactions: [["emoji": "👍", "count": 6, "reactedByMe": true]])
        let (controller, api, store) = makeController()
        let timeline = try await timeline(message: original, store: store)
        let operation = Task { await controller.toggle(message: original, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        await api.finishRead(0, with: .success(original))
        await api.waitForRequests(2)
        store.apply(reactionEvent(broadcast))
        XCTAssertNil(visibleMessage(timeline)?.reactions.first?.reactedByMe)
        await api.finishMutation(1, with: .success(()))
        await api.waitForRequests(3)
        await api.finishRead(2, with: .success(personalized))
        await operation.value

        XCTAssertEqual(visibleMessage(timeline)?.reactions, personalized.reactions)
        XCTAssertNil(controller.error)
    }

    func testFailedMutationDoesNotRollBackNewerRealtimeState() async throws {
        let original = try message()
        let remote = try message(reactions: [["emoji": "❤️", "count": 2]])
        let (controller, api, store) = makeController()
        let timeline = try await timeline(message: original, store: store)
        let operation = Task { await controller.toggle(message: original, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        await api.finishRead(0, with: .success(original))
        await api.waitForRequests(2)
        store.apply(reactionEvent(remote))
        await api.finishMutation(1, with: .failure(APIError.unavailable))
        await operation.value

        XCTAssertEqual(visibleMessage(timeline)?.reactions, remote.reactions)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(controller.pendingMessageIDs.isEmpty)
    }

    func testConcurrentPreflightChangeDoesNotChooseMutationFromStalePersonalization() async throws {
        let original = try message()
        let remote = try message(reactions: [["emoji": "👍", "count": 2]])
        let (controller, api, store) = makeController()
        let timeline = try await timeline(message: original, store: store)
        let operation = Task { await controller.toggle(message: original, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        store.apply(reactionEvent(remote))
        await api.finishRead(0, with: .success(original))
        await operation.value

        let requests = await api.requests()
        XCTAssertEqual(requests, [.get])
        XCTAssertEqual(visibleMessage(timeline)?.reactions, remote.reactions)
        XCTAssertNotNil(controller.error)
    }

    func testDeletionDuringReadbackCannotBeResurrectedByReactionResponse() async throws {
        let original = try message()
        let stale = try message(reactions: [["emoji": "👍", "count": 1, "reactedByMe": true]])
        let (controller, api, store) = makeController()
        let timeline = try await timeline(message: original, store: store)
        let operation = Task { await controller.toggle(message: original, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        await api.finishRead(0, with: .success(original))
        await api.waitForRequests(2)
        await api.finishMutation(1, with: .success(()))
        await api.waitForRequests(3)
        store.apply(.messageDeleted(original.redactedForDeletion()))
        await api.finishRead(2, with: .success(stale))
        await operation.value

        XCTAssertEqual(visibleMessage(timeline)?.isDeleted, true)
        XCTAssertEqual(visibleMessage(timeline)?.reactions, [])
    }

    func testFiveOwnedReactionsBlocksAdditionButAllowsRemoval() async throws {
        let full = try message(reactions: (0..<5).map { ["emoji": "reaction-\($0)", "count": 1, "reactedByMe": true] })
        let (controller, api, _) = makeController()
        let adding = Task { await controller.toggle(message: full, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        await api.finishRead(0, with: .success(full))
        await adding.value
        let blockedRequests = await api.requests()
        XCTAssertEqual(blockedRequests, [.get])
        XCTAssertNotNil(controller.error)

        let removing = Task { await controller.toggle(message: full, emoji: "reaction-0", currentUserID: 1) }
        await api.waitForRequests(2)
        await api.finishRead(1, with: .success(full))
        await api.waitForRequests(3)
        await api.finishMutation(2, with: .success(()))
        await api.waitForRequests(4)
        await api.finishRead(3, with: .success(full.replacingReactions(Array(full.reactions.dropFirst()))))
        await removing.value
        let requests = await api.requests()
        XCTAssertEqual(requests, [.get, .get, .delete("reaction-0"), .get])
        XCTAssertNil(controller.error)
    }

    func testFiftyDistinctReactionsBlocksNewEmojiButAllowsJoiningExistingEmoji() async throws {
        let full = try message(
            reactions: (0..<50).map { ["emoji": "reaction-\($0)", "count": 1, "reactedByMe": false] })
        let (controller, api, _) = makeController()
        let adding = Task { await controller.toggle(message: full, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        await api.finishRead(0, with: .success(full))
        await adding.value
        let blockedRequests = await api.requests()
        XCTAssertEqual(blockedRequests, [.get])
        XCTAssertNotNil(controller.error)

        let joining = Task { await controller.toggle(message: full, emoji: "reaction-0", currentUserID: 1) }
        await api.waitForRequests(2)
        await api.finishRead(1, with: .success(full))
        await api.waitForRequests(3)
        await api.finishMutation(2, with: .success(()))
        await api.waitForRequests(4)
        await api.finishRead(3, with: .success(full))
        await joining.value
        let requests = await api.requests()
        XCTAssertEqual(requests, [.get, .get, .put("reaction-0"), .get])
        XCTAssertNil(controller.error)
    }

    func testResetDiscardsLateResponseWithoutClearingNewSessionPendingIntent() async throws {
        let original = try message()
        let full = try message(reactions: (0..<5).map { ["emoji": "reaction-\($0)", "count": 1, "reactedByMe": true] })
        let (controller, api, store) = makeController()
        let old = Task { await controller.toggle(message: original, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        controller.reset()
        store.reset()
        let new = Task { await controller.toggle(message: full, emoji: "❤️", currentUserID: 2) }
        await api.waitForRequests(2)
        await api.finishRead(0, with: .failure(APIError.invalidToken))
        await old.value
        XCTAssertEqual(controller.pendingMessageIDs, [original.id])
        XCTAssertNil(controller.error)
        await api.finishRead(1, with: .success(full))
        await new.value
        XCTAssertTrue(controller.pendingMessageIDs.isEmpty)
    }

    func testInvalidAuthenticationInvalidatesSessionAndClearsPendingState() async throws {
        let original = try message()
        let api = HeldReactionAPI()
        let store = ConversationMessageStore()
        var invalidations = 0
        let controller = MessageReactionController(apiClient: api, messageStore: store) { invalidations += 1 }
        let operation = Task { await controller.toggle(message: original, emoji: "👍", currentUserID: 1) }
        await api.waitForRequests(1)
        await api.finishRead(0, with: .failure(APIError.invalidToken))
        await operation.value
        XCTAssertEqual(invalidations, 1)
        XCTAssertTrue(controller.pendingMessageIDs.isEmpty)
        XCTAssertNotNil(controller.error)
    }

    private func makeController() -> (MessageReactionController, HeldReactionAPI, ConversationMessageStore) {
        let api = HeldReactionAPI()
        let store = ConversationMessageStore()
        return (MessageReactionController(apiClient: api, messageStore: store, onInvalidToken: {}), api, store)
    }

    private func message(reactions: [[String: Any]] = []) throws -> MessageResponse {
        try TimelineTestFixtures.message(id: "message", at: 1, fields: ["reactions": reactions])
    }

    private func reactionEvent(_ message: MessageResponse) -> RealtimeServerEvent {
        .reactionUpdated(.init(messageId: message.id, chatId: message.chatId, reactions: message.reactions))
    }

    private func timeline(message: MessageResponse, store: ConversationMessageStore) async throws
        -> ConversationTimelineModel
    {
        let source = ReactionTimelineSource(page: try TimelineTestFixtures.page([message]))
        let model = ConversationTimelineModel(
            chatID: message.chatId, currentUserID: 1, isGroupChat: true, source: source, messageStore: store)
        await model.loadInitial()
        return model
    }

    private func visibleMessage(_ model: ConversationTimelineModel) -> MessageResponse? {
        model.rows.compactMap { item -> MessageResponse? in
            guard case .message(let row) = item else { return nil }
            return row.entry.remoteMessage
        }.first
    }
}

@MainActor
private final class ReactionTimelineSource: TimelineMessageSource {
    let page: ListMessagesResponse
    init(page: ListMessagesResponse) { self.page = page }
    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse { page }
}

private actor HeldReactionAPI: ChahuaAPIClient {
    enum Request: Equatable, Sendable {
        case get
        case put(String)
        case delete(String)
    }
    private var recorded: [Request] = []
    private var reads: [Int: CheckedContinuation<MessageResponse, Error>] = [:]
    private var mutations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func requests() -> [Request] { recorded }

    func waitForRequests(_ count: Int) async {
        guard recorded.count < count else { return }
        await withCheckedContinuation { waiter = (count, $0) }
    }

    private func notifyWaiter() {
        guard let waiter, recorded.count >= waiter.count else { return }
        self.waiter = nil
        waiter.continuation.resume()
    }

    func finishRead(_ index: Int, with result: Result<MessageResponse, Error>) {
        reads.removeValue(forKey: index)?.resume(with: result)
    }

    func finishMutation(_ index: Int, with result: Result<Void, Error>) {
        mutations.removeValue(forKey: index)?.resume(with: result)
    }

    // Deliberately completes even after cancellation to exercise session fencing.
    func getMessage(chatID: String, messageID: String) async throws -> MessageResponse {
        let index = recorded.count
        recorded.append(.get)
        return try await withCheckedThrowingContinuation {
            reads[index] = $0
            notifyWaiter()
        }
    }

    func putReaction(chatID: String, messageID: String, emoji: String) async throws {
        try await mutate(.put(emoji))
    }

    func deleteReaction(chatID: String, messageID: String, emoji: String) async throws {
        try await mutate(.delete(emoji))
    }

    private func mutate(_ request: Request) async throws {
        let index = recorded.count
        recorded.append(request)
        try await withCheckedThrowingContinuation {
            mutations[index] = $0
            notifyWaiter()
        }
    }

    func authenticate(candidateJWT: String) async throws -> MeResponse { throw APIError.unavailable }
    func createDevSession(uid: Int32, clientID: String) async throws -> String { throw APIError.unavailable }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse { throw APIError.unavailable }
    func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse { throw APIError.unavailable }
    func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody) async throws -> MessageResponse { throw APIError.unavailable }
    func markChatRead(chatID: String, messageID: String) async throws -> ReadStateResponse { throw APIError.unavailable }
    func markThreadRead(chatID: String, threadID: String, messageID: String) async throws -> ReadStateResponse { throw APIError.unavailable }
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        throw APIError.unavailable
    }
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse {
        throw APIError.unavailable
    }
    func groupInfo(chatID: String) async throws -> GroupInfoResponse { throw APIError.unavailable }
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse { throw APIError.unavailable }
}
