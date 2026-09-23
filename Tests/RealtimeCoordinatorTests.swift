import ChahuaAPI
import Combine
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class RealtimeCoordinatorTests: XCTestCase {
    func testExpirySuspendedInStorageCannotSignOutReplacementAccount() async {
        let storage = RealtimeExpiryStorage()
        let session = AuthSessionModel(
            apiClient: RealtimeTestHTTP(),
            credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: storage
        )
        await session.signIn(candidateJWT: "1")
        let expiry = Task { await session.sessionDidExpire() }
        await eventually { await storage.isDeleting }
        await session.signIn(candidateJWT: "2")
        await storage.releaseDelete()
        await expiry.value
        guard case .authenticated(let me) = session.state else {
            XCTFail("Old expiry signed out replacement account")
            return
        }
        XCTAssertEqual(me.uid, 2)
    }

    func testSceneTransitionsKeepSocketAndHeartbeatsPublishCurrentPresence() async {
        let clock = RealtimeTestClock()
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket])
        let store = ChatStore(
            apiClient: RealtimeTestHTTP(),
            outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: {},
            sleep: { try await clock.sleep($0) }, jitter: { 0 })
        let first = UUID()
        let second = UUID()
        coordinator.setSceneActive(id: first, active: true)
        coordinator.setSceneActive(id: second, active: true)
        coordinator.setSession(uid: 1)
        await eventually { await socket.frames == [.appState(.active)] }
        coordinator.removeScene(id: first)
        coordinator.removeScene(id: second)
        await eventually { await socket.frames == [.appState(.active), .appState(.inactive)] }
        await eventually { await clock.hasSleep(seconds: 10) }
        await clock.advance(seconds: 10)
        await eventually { await socket.frames.last == .ping(.inactive) }
        await eventually { await clock.sleepCount(seconds: 10) == 2 }
        await socket.emit(.pong)
        await eventually { await clock.sleepCount(seconds: 10) == 1 }
        coordinator.setSceneActive(id: first, active: true)
        await eventually { await socket.frames.last == .appState(.active) }
        await clock.advance(seconds: 10)
        await eventually { await socket.frames.last == .ping(.active) }
        let frames = await socket.frames
        XCTAssertEqual(
            frames,
            [
                .appState(.active), .appState(.inactive), .ping(.inactive),
                .appState(.active), .ping(.active),
            ])
        let closed = await socket.closed
        let opens = await provider.opens
        XCTAssertFalse(closed)
        XCTAssertEqual(opens, 1)
        coordinator.setSession(uid: nil)
        await eventually { await socket.closed }
    }

    func testMissingPongReconnectsWhileInactiveWithoutAdvertisingActive() async {
        let clock = RealtimeTestClock()
        let first = RealtimeTestSocket()
        let second = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [first, second])
        let coordinator = RealtimeCoordinator(
            provider: provider,
            store: ChatStore(
                apiClient: RealtimeTestHTTP(),
                outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {}),
            onInvalidToken: {}, sleep: { try await clock.sleep($0) }, jitter: { 0 }
        )
        coordinator.setSession(uid: 1)
        await eventually { await first.frames == [.appState(.inactive)] }
        await eventually { await clock.hasSleep(seconds: 10) }
        await clock.advance(seconds: 10)
        await eventually { await first.frames == [.appState(.inactive), .ping(.inactive)] }
        await eventually { await clock.sleepCount(seconds: 10) == 2 }
        await clock.advance(seconds: 10)
        await eventually { await first.closed }
        await eventually { await clock.hasSleep(seconds: 1) }
        await clock.advance(seconds: 1)
        await eventually { await second.frames == [.appState(.inactive)] }
        await eventually { await clock.hasSleep(seconds: 10) }
        await clock.advance(seconds: 10)
        await eventually { await second.frames == [.appState(.inactive), .ping(.inactive)] }
        let opens = await provider.opens
        XCTAssertEqual(opens, 2)
        coordinator.setSession(uid: nil)
    }

    func testSignOutDiscardsLateSocketOpening() async {
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket], holdOpen: true)
        var expired = false
        let coordinator = RealtimeCoordinator(
            provider: provider,
            store: ChatStore(
                apiClient: RealtimeTestHTTP(),
                outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {}),
            onInvalidToken: { expired = true }
        )
        coordinator.setSession(uid: 1)
        coordinator.setSceneActive(id: UUID(), active: true)
        await eventually { await provider.opens == 1 }
        coordinator.setSession(uid: nil)
        await provider.releaseOpen()
        await eventually { await socket.closed }
        XCTAssertFalse(expired)
    }

    func testFocusLossDuringOpeningUsesInactiveInitialState() async {
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket], holdOpen: true)
        let coordinator = RealtimeCoordinator(
            provider: provider,
            store: ChatStore(
                apiClient: RealtimeTestHTTP(),
                outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {}),
            onInvalidToken: {}
        )
        let scene = UUID()
        coordinator.setSceneActive(id: scene, active: true)
        coordinator.setSession(uid: 1)
        await eventually { await provider.opens == 1 }
        coordinator.setSceneActive(id: scene, active: false)
        await provider.releaseOpen()
        await eventually { await socket.frames == [.appState(.inactive)] }
        let closed = await socket.closed
        XCTAssertFalse(closed)
        coordinator.setSession(uid: nil)
    }

    func testFocusRestoredDuringInactiveSendRetainsSocketAndFrameOrder() async {
        let socket = RealtimeTestSocket()
        let coordinator = RealtimeCoordinator(
            provider: RealtimeTestProvider(sockets: [socket]),
            store: ChatStore(
                apiClient: RealtimeTestHTTP(),
                outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {}),
            onInvalidToken: {}
        )
        let scene = UUID()
        coordinator.setSceneActive(id: scene, active: true)
        coordinator.setSession(uid: 1)
        await eventually { await socket.frames == [.appState(.active)] }
        await socket.holdNextAppState()
        coordinator.setSceneActive(id: scene, active: false)
        await eventually { await socket.isHoldingAppState }
        coordinator.setSceneActive(id: scene, active: true)
        await socket.releaseAppState()
        await eventually {
            await socket.frames == [.appState(.active), .appState(.inactive), .appState(.active)]
        }
        let closed = await socket.closed
        XCTAssertFalse(closed)
        coordinator.setSession(uid: nil)
    }

    func testAccountReplacementClosesOnlyOldSocketAndPreservesScenePresence() async {
        let first = RealtimeTestSocket()
        let second = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [first, second])
        let coordinator = RealtimeCoordinator(
            provider: provider,
            store: ChatStore(
                apiClient: RealtimeTestHTTP(),
                outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {}),
            onInvalidToken: {}
        )
        let scene = UUID()
        coordinator.setSceneActive(id: scene, active: true)
        coordinator.setSession(uid: 1)
        await eventually { await first.frames == [.appState(.active)] }
        coordinator.setSession(uid: 2)
        await eventually { await first.closed }
        await eventually { await second.frames == [.appState(.active)] }
        coordinator.setSceneActive(id: scene, active: false)
        await eventually { await second.frames == [.appState(.active), .appState(.inactive)] }
        let oldFrames = await first.frames
        let replacementClosed = await second.closed
        XCTAssertEqual(oldFrames, [.appState(.active)])
        XCTAssertFalse(replacementClosed)
        coordinator.setSession(uid: nil)
    }

    func testInactiveOpenDefersBulkRecoveryUntilActivationWithoutReconnecting() async {
        let api = RealtimeTestHTTP()
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket])
        let coordinator = RealtimeCoordinator(
            provider: provider,
            store: ChatStore(
                apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {}
            ),
            onInvalidToken: {}
        )
        coordinator.setSession(uid: 1)
        await eventually { await socket.frames == [.appState(.inactive)] }
        await socket.emit(.pong)
        for _ in 0..<20 { await Task.yield() }
        let refreshedWhileInactive = await api.chatRequestStarted
        XCTAssertFalse(refreshedWhileInactive)
        coordinator.setSceneActive(id: UUID(), active: true)
        await eventually { await api.chatRequestStarted }
        let opens = await provider.opens
        XCTAssertEqual(opens, 1)
        coordinator.setSession(uid: nil)
    }

    func testRecoveryDoesNotBlockLaterEventDelivery() async throws {
        let api = RealtimeTestHTTP(holdChats: true)
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let socket = RealtimeTestSocket()
        let coordinator = RealtimeCoordinator(
            provider: RealtimeTestProvider(sockets: [socket]), store: store, onInvalidToken: {})
        var received = false
        let observation = store.conversationMessages.changes.sink { change in
            if case .realtime(.threadUpdate(let payload)) = change {
                received = payload.replyCount == 9
            }
        }
        coordinator.setSession(uid: 1)
        coordinator.setSceneActive(id: UUID(), active: true)
        await socket.emit(.pong)
        await eventually { await api.chatRequestStarted }
        await socket.emit(.presenceUpdate(PresenceUpdatePayload(activeConnections: 1)))
        await socket.emit(.unknown(type: "futureEvent"))
        await socket.emit(
            .threadUpdate(
                ThreadUpdatePayload(
                    threadRootId: "100", chatId: "1", lastReplyAt: Date(), replyCount: 9)))
        await eventually { received }
        XCTAssertTrue(received)
        coordinator.setSession(uid: nil)
        await api.releaseChats()
        withExtendedLifetime(observation) {}
    }

    private func eventually(
        _ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<5_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Expected asynchronous transition did not occur", file: file, line: line)
    }
}

private actor RealtimeTestClock {
    private struct Waiter {
        let deadline: Double
        let duration: Double
        let continuation: CheckedContinuation<Void, Error>
    }
    private var now = 0.0
    private var waiters: [UUID: Waiter] = [:]

    func sleep(_ duration: Duration) async throws {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(
                    deadline: now + seconds, duration: seconds, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func hasSleep(seconds: Double) -> Bool { waiters.values.contains { $0.duration == seconds } }
    func sleepCount(seconds: Double) -> Int {
        waiters.values.filter { $0.duration == seconds }.count
    }
    func advance(seconds: Double) {
        now += seconds
        let due = waiters.filter { $0.value.deadline <= now }
        for (id, waiter) in due {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }
    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private actor RealtimeTestSocket: RealtimeConnection {
    enum Frame: Equatable, Sendable {
        case appState(RealtimeAppState)
        case ping(RealtimeAppState)
    }
    private(set) var frames: [Frame] = []
    private var events: [RealtimeServerEvent] = []
    private var receiver: CheckedContinuation<RealtimeServerEvent, Error>?
    private var holdsNextAppState = false
    private var heldAppState: CheckedContinuation<Void, Never>?
    var isHoldingAppState: Bool { heldAppState != nil }
    func holdNextAppState() { holdsNextAppState = true }
    func releaseAppState() {
        heldAppState?.resume()
        heldAppState = nil
    }
    private(set) var closed = false
    func receive() async throws -> RealtimeServerEvent {
        if closed { throw CancellationError() }
        if !events.isEmpty { return events.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func sendPing(state: RealtimeAppState) async throws {
        guard !closed else { throw CancellationError() }
        frames.append(.ping(state))
    }
    func sendAppState(_ state: RealtimeAppState) async throws {
        if holdsNextAppState {
            holdsNextAppState = false
            await withCheckedContinuation { heldAppState = $0 }
        }
        guard !closed else { throw CancellationError() }
        frames.append(.appState(state))
    }
    func close() {
        closed = true
        releaseAppState()
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
    func emit(_ event: RealtimeServerEvent) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: event)
        } else {
            events.append(event)
        }
    }
}

private actor RealtimeTestProvider: RealtimeConnectionProviding {
    private var sockets: [RealtimeTestSocket]
    private let holdOpen: Bool
    private var opening: CheckedContinuation<Void, Never>?
    private(set) var opens = 0
    init(sockets: [RealtimeTestSocket], holdOpen: Bool = false) {
        self.sockets = sockets
        self.holdOpen = holdOpen
    }
    func openRealtimeConnection() async throws -> any RealtimeConnection {
        opens += 1
        if holdOpen { await withCheckedContinuation { opening = $0 } }
        guard !sockets.isEmpty else { throw APIError.unavailable }
        return sockets.removeFirst()
    }
    func releaseOpen() {
        opening?.resume()
        opening = nil
    }
}

private actor RealtimeTestHTTP: ChahuaAPIClient {
    private let holdChats: Bool
    private var chats: CheckedContinuation<Void, Never>?
    private(set) var chatRequestStarted = false
    init(holdChats: Bool = false) { self.holdChats = holdChats }
    func authenticate(candidateJWT: String) async throws -> MeResponse {
        try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                "{\"uid\":\(Int(candidateJWT) ?? 1),\"username\":\"Test\",\"gender\":0,\"stickerPackOrder\":[],\"permissions\":[]}"
                    .utf8
            ))
    }
    func createDevSession(uid: Int32, clientID: String) async throws -> String {
        throw APIError.unavailable
    }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func attachmentConfig() async throws -> AttachmentConfigResponse { throw APIError.unavailable }
    func requestAttachmentUpload(
        fileName: String, contentType: String, size: Int64, width: Int, height: Int, order: Int
    ) async throws -> OutgoingUploadAllocation { throw APIError.unavailable }
    func listOwnedStickerPacks() async throws -> [StickerPackSummary] { throw APIError.unavailable }
    func listSubscribedStickerPacks() async throws -> [StickerPackSummary] {
        throw APIError.unavailable
    }
    func listFavoriteStickers() async throws -> [MessageStickerResponse] {
        throw APIError.unavailable
    }
    func getSticker(id: String) async throws -> StickerDetailResponse { throw APIError.unavailable }
    func getStickerPack(id: String) async throws -> StickerPackDetailResponse {
        throw APIError.unavailable
    }
    func setStickerFavorite(id: String, favorite: Bool) async throws { throw APIError.unavailable }
    func setStickerPackSubscription(id: String, subscribed: Bool) async throws {
        throw APIError.unavailable
    }
    func groupInfo(chatID: String) async throws -> GroupInfoResponse { throw APIError.unavailable }
    func listMembers(chatID: String, query: ListMembersQuery) async throws -> ListMembersResponse {
        throw APIError.unavailable
    }
    func updateGroupMemberRole(chatID: String, uid: Int32, role: GroupRole) async throws
        -> MemberResponse
    { throw APIError.unavailable }
    func removeGroupMember(chatID: String, uid: Int32) async throws { throw APIError.unavailable }
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse {
        throw APIError.unavailable
    }
    func getMessage(chatID: String, messageID: String) async throws -> MessageResponse {
        throw APIError.unavailable
    }
    func deleteMessage(chatID: String, messageID: String) async throws {
        throw APIError.unavailable
    }
    func markChatRead(chatID: String, messageID: String) async throws -> ReadStateResponse {
        throw APIError.unavailable
    }
    func markChatUnread(chatID: String) async throws -> ReadStateResponse {
        throw APIError.unavailable
    }
    func archiveChat(chatID: String) async throws { throw APIError.unavailable }
    func unarchiveChat(chatID: String) async throws { throw APIError.unavailable }
    func archiveThread(chatID: String, threadID: String) async throws { throw APIError.unavailable }
    func unarchiveThread(chatID: String, threadID: String) async throws {
        throw APIError.unavailable
    }
    func muteChat(chatID: String, durationSeconds: Int?) async throws -> MuteResponse {
        throw APIError.unavailable
    }
    func unmuteChat(chatID: String) async throws { throw APIError.unavailable }
    func markThreadRead(chatID: String, threadID: String, messageID: String) async throws
        -> ReadStateResponse
    { throw APIError.unavailable }
    func putReaction(chatID: String, messageID: String, emoji: String) async throws {
        throw APIError.unavailable
    }
    func deleteReaction(chatID: String, messageID: String, emoji: String) async throws {
        throw APIError.unavailable
    }
    func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse {
        .init(threads: [])
    }
    func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody) async throws
        -> MessageResponse
    { throw APIError.unavailable }
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse {
        chatRequestStarted = true
        if holdChats { await withCheckedContinuation { chats = $0 } }
        return ListChatsResponse(chats: [])
    }
    func releaseChats() {
        chats?.resume()
        chats = nil
    }
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse
    { throw APIError.unavailable }
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse {
        throw APIError.unavailable
    }
}

private actor RealtimeExpiryStorage: SessionTokenStorage {
    private var deletion: CheckedContinuation<Void, Never>?
    var isDeleting: Bool { deletion != nil }
    func loadToken() async throws -> String? { nil }
    func saveToken(_ token: String) async throws {}
    func deleteToken() async throws { await withCheckedContinuation { deletion = $0 } }
    func releaseDelete() {
        deletion?.resume()
        deletion = nil
    }
}
