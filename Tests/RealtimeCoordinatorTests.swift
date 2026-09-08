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

    func testTwoScenesShareSocketAndLastSceneStopsRetries() async {
        let clock = RealtimeTestClock()
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket])
        let store = ChatStore(apiClient: RealtimeTestHTTP(), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(provider: provider, store: store, onInvalidToken: {}, sleep: { try await clock.sleep($0) }, jitter: { 0 })
        let first = UUID(), second = UUID()
        coordinator.setSession(uid: 1)
        coordinator.setSceneActive(id: first, active: true)
        coordinator.setSceneActive(id: second, active: true)
        await eventually { await provider.opens == 1 }
        await socket.emit(.pong)
        coordinator.removeScene(id: first)
        for _ in 0..<20 { await Task.yield() }
        let closedWhileSecondActive = await socket.closed
        XCTAssertFalse(closedWhileSecondActive)
        coordinator.removeScene(id: second)
        await eventually { await socket.closed }
        await clock.advance(seconds: 100)
        for _ in 0..<20 { await Task.yield() }
        let opens = await provider.opens
        XCTAssertEqual(opens, 1)
    }

    func testMissingFirstPongClosesAndReconnects() async {
        let clock = RealtimeTestClock()
        let first = RealtimeTestSocket(), second = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [first, second])
        let coordinator = RealtimeCoordinator(
            provider: provider, store: ChatStore(apiClient: RealtimeTestHTTP(), onInvalidToken: {}),
            onInvalidToken: {}, sleep: { try await clock.sleep($0) }, jitter: { 0 }
        )
        let scene = UUID()
        coordinator.setSession(uid: 1)
        coordinator.setSceneActive(id: scene, active: true)
        await eventually { await clock.hasSleep(seconds: 10) }
        await clock.advance(seconds: 10)
        await eventually { await first.closed }
        await eventually { await clock.hasSleep(seconds: 1) }
        await clock.advance(seconds: 1)
        await eventually { await provider.opens == 2 }
        await second.emit(.pong)
        coordinator.removeScene(id: scene)
    }

    func testSignOutDiscardsLateSocketOpening() async {
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket], holdOpen: true)
        var expired = false
        let coordinator = RealtimeCoordinator(
            provider: provider, store: ChatStore(apiClient: RealtimeTestHTTP(), onInvalidToken: {}),
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

    func testRecoveryDoesNotBlockLaterEventDelivery() async throws {
        let api = RealtimeTestHTTP(holdChats: true)
        let store = ChatStore(apiClient: api, onInvalidToken: {})
        let socket = RealtimeTestSocket()
        let coordinator = RealtimeCoordinator(provider: RealtimeTestProvider(sockets: [socket]), store: store, onInvalidToken: {})
        var received = false
        let observation = store.conversationMessages.changes.sink { change in
            if case .realtime(.threadUpdate(let payload)) = change { received = payload.replyCount == 9 }
        }
        coordinator.setSession(uid: 1)
        coordinator.setSceneActive(id: UUID(), active: true)
        await socket.emit(.pong)
        await eventually { await api.chatRequestStarted }
        await socket.emit(.presenceUpdate(PresenceUpdatePayload(activeConnections: 1)))
        await socket.emit(.unknown(type: "futureEvent"))
        await socket.emit(.threadUpdate(ThreadUpdatePayload(threadRootId: "100", chatId: "1", lastReplyAt: Date(), replyCount: 9)))
        await eventually { received }
        XCTAssertTrue(received)
        coordinator.setSession(uid: nil)
        await api.releaseChats()
        withExtendedLifetime(observation) {}
    }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
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
                waiters[id] = Waiter(deadline: now + seconds, duration: seconds, continuation: continuation)
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func hasSleep(seconds: Double) -> Bool { waiters.values.contains { $0.duration == seconds } }
    func advance(seconds: Double) {
        now += seconds
        let due = waiters.filter { $0.value.deadline <= now }
        for (id, waiter) in due { waiters.removeValue(forKey: id); waiter.continuation.resume() }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
}

private actor RealtimeTestSocket: RealtimeConnection {
    private var events: [RealtimeServerEvent] = []
    private var receiver: CheckedContinuation<RealtimeServerEvent, Error>?
    private(set) var closed = false
    func receive() async throws -> RealtimeServerEvent {
        if closed { throw CancellationError() }
        if !events.isEmpty { return events.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func sendPing(state: RealtimeAppState) async throws {}
    func sendAppState(_ state: RealtimeAppState) async throws {}
    func close() {
        closed = true
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
    func emit(_ event: RealtimeServerEvent) {
        if let receiver { self.receiver = nil; receiver.resume(returning: event) }
        else { events.append(event) }
    }
}

private actor RealtimeTestProvider: RealtimeConnectionProviding {
    private var sockets: [RealtimeTestSocket]
    private let holdOpen: Bool
    private var opening: CheckedContinuation<Void, Never>?
    private(set) var opens = 0
    init(sockets: [RealtimeTestSocket], holdOpen: Bool = false) { self.sockets = sockets; self.holdOpen = holdOpen }
    func openRealtimeConnection() async throws -> any RealtimeConnection {
        opens += 1
        if holdOpen { await withCheckedContinuation { opening = $0 } }
        guard !sockets.isEmpty else { throw APIError.unavailable }
        return sockets.removeFirst()
    }
    func releaseOpen() { opening?.resume(); opening = nil }
}

private actor RealtimeTestHTTP: ChahuaAPIClient {
    private let holdChats: Bool
    private var chats: CheckedContinuation<Void, Never>?
    private(set) var chatRequestStarted = false
    init(holdChats: Bool = false) { self.holdChats = holdChats }
    func authenticate(candidateJWT: String) async throws -> MeResponse {
        try JSONDecoder().decode(MeResponse.self, from: Data(
            "{\"uid\":\(Int(candidateJWT) ?? 1),\"username\":\"Test\",\"gender\":0,\"stickerPackOrder\":[],\"permissions\":[]}".utf8
        ))
    }
    func createDevSession(uid: Int32, clientID: String) async throws -> String { throw APIError.unavailable }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse {
        chatRequestStarted = true
        if holdChats { await withCheckedContinuation { chats = $0 } }
        return ListChatsResponse(chats: [])
    }
    func releaseChats() { chats?.resume(); chats = nil }
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse { throw APIError.unavailable }
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse { throw APIError.unavailable }
}

private actor RealtimeExpiryStorage: SessionTokenStorage {
    private var deletion: CheckedContinuation<Void, Never>?
    var isDeleting: Bool { deletion != nil }
    func loadToken() async throws -> String? { nil }
    func saveToken(_ token: String) async throws {}
    func deleteToken() async throws { await withCheckedContinuation { deletion = $0 } }
    func releaseDelete() { deletion?.resume(); deletion = nil }
}
