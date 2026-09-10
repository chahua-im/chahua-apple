import ChahuaAPI
import Combine
import Foundation
import XCTest
@testable import chahua_apple

@MainActor
final class OutgoingMessageQueueTests: XCTestCase {
    func testFailureAtomicallyPausesSuccessorsWithoutBlockingAnotherChat() async throws {
        let h = try await openHarness()
        var transitions: [[LocalOutgoingMessage.State]] = []
        let observation = h.queue.events.sink { event in
            if case .snapshot(let snapshot) = event, snapshot.chatID == "chat" {
                transitions.append(snapshot.outgoing.map(\.state))
            }
        }
        let rows = try await enqueueABC(h)
        let initialRequests = await h.api.requests()
        XCTAssertEqual(initialRequests.map(\.body.message), ["A"])
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually { h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .failed, .failed] }
        XCTAssertTrue(transitions.contains([.failed, .failed, .failed]))
        XCTAssertFalse(transitions.contains([.failed, .queued, .queued]))
        try await h.queue.enqueueText(chatID: "other", text: "independent", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.chatID), ["chat", "other"])
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.clientGeneratedID), rows.map(\.clientGeneratedID))
        observation.cancel()
        await h.close()
    }

    func testRetryOnePromotesOnlySelectionAndPreservesIdentityAndDisplayOrder() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.enqueueText(chatID: "chat", text: "D", clearedDraftRevision: 4)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.failed, .failed, .failed, .failed])
        let pausedRequests = await h.api.requests()
        XCTAssertEqual(pausedRequests.count, 1)
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID, scope: .message)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests[1].body.clientGeneratedId, rows[1].clientGeneratedID)
        XCTAssertEqual(requests[1].body.message, "B")
        let retried = h.queue.pendingMessages(chatID: "chat")
        XCTAssertEqual(retried.map(\.text), ["B", "A", "C", "D"])
        let displayed = retried.sorted { $0.enqueueSequence < $1.enqueueSequence }
        XCTAssertEqual(displayed.map(\.text), ["A", "B", "C", "D"])
        for original in rows {
            let current = try XCTUnwrap(retried.first { $0.clientGeneratedID == original.clientGeneratedID })
            XCTAssertEqual(current.enqueuedAt, original.enqueuedAt)
            XCTAssertEqual(current.enqueueSequence, original.enqueueSequence)
        }
        await h.api.finish(1, with: .success(try response(requests[1])))
        try await eventually { h.queue.pendingMessages(chatID: "chat").map(\.text) == ["A", "C", "D"] }
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.failed, .failed, .failed])
        await h.close()
    }

    func testRetrySubsequentSendsSelectedBatchOnlyAndRepeatedTapsDoNotOverlap() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID, scope: .messageAndSubsequent)
        try await eventually { await h.api.requests().count == 2 }
        for _ in 0..<3 {
            try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID, scope: .messageAndSubsequent)
        }
        var requests = await h.api.requests()
        XCTAssertEqual(requests.count, 2)
        await h.api.finish(1, with: .success(try response(requests[1])))
        try await eventually { await h.api.requests().count == 3 }
        requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.body.message), ["A", "B", "C"])
        XCTAssertEqual(requests[2].body.clientGeneratedId, rows[2].clientGeneratedID)
        await h.api.finish(2, with: .success(try response(requests[2])))
        try await eventually { h.queue.pendingMessages(chatID: "chat").map(\.text) == ["A"] }
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.state, .failed)
        let concurrency = await h.api.maximumConcurrency(chatID: "chat")
        XCTAssertEqual(concurrency, 1)
        await h.close()
    }

    func testRetryFailureDoesNotAttemptRemainingBatchAndReusesOriginalBody() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID, scope: .messageAndSubsequent)
        try await eventually { await h.api.requests().count == 2 }
        await h.api.finish(1, with: .failure(QueueTestError.network))
        try await eventually { h.queue.pendingMessages(chatID: "chat").allSatisfy { $0.state == .failed } }
        let requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.body.message), ["A", "B"])
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID, scope: .message)
        try await eventually { await h.api.requests().count == 3 }
        let repeated = await h.api.requests()
        XCTAssertEqual(repeated[1].body, repeated[2].body)
        await h.close()
    }

    func testRetryDuringSendingDoesNotPreemptAndMovesAheadOfFailedRows() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID, scope: .message)
        try await eventually { await h.api.requests().count == 2 }
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[2].clientGeneratedID, scope: .message)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["B", "C", "A"])
        let held = await h.api.requests()
        XCTAssertEqual(held.count, 2)
        await h.api.finish(1, with: .success(try response(held[1])))
        try await eventually { await h.api.requests().count == 3 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests[2].body.message, "C")
        let concurrency = await h.api.maximumConcurrency(chatID: "chat")
        XCTAssertEqual(concurrency, 1)
        await h.close()
    }

    func testSocketFirstAcknowledgementWaitsForHTTPAndLateFailureDoesNotPoisonSuccessor() async throws {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        let first = try await firstRequest(h.api)
        let message = try response(first)
        let handled = await h.queue.acceptAcknowledgement(message)
        XCTAssertTrue(handled)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["B", "C"])
        let stillHeld = await h.api.requests()
        XCTAssertEqual(stillHeld.count, 1)
        let duplicate = await h.queue.acceptAcknowledgement(message)
        XCTAssertFalse(duplicate)
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually { await h.api.requests().count == 2 }
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.sending, .queued])
        await h.close()
        let reopened = try await h.openStore(uid: 1)
        let restored = try await reopened.restore()
        XCTAssertFalse(restored.flatMap(\.outgoing).contains { $0.clientGeneratedID == message.clientGeneratedId })
    }

    func testSocketFirstThenHTTPSuccessStillPublishesValidatedAcknowledgement() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        let message = try response(request)
        var acknowledged: [String] = []
        let observation = h.queue.events.sink {
            if case .acknowledged(_, let message) = $0 { acknowledged.append(message.id) }
        }
        _ = await h.queue.acceptAcknowledgement(message)
        await h.api.finish(0, with: .success(message))
        try await eventually { acknowledged.count == 2 }
        XCTAssertEqual(Set(acknowledged), [message.id])
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat"), [])
        observation.cancel()
        await h.close()
    }

    func testHTTPFirstIsDurablyDeletedAndRejectsUnrelatedAcknowledgements() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        for invalid in [
            try TimelineTestFixtures.message(id: "wrong-chat", chatID: "other", at: 1, clientGeneratedID: request.body.clientGeneratedId),
            try TimelineTestFixtures.message(id: "wrong-sender", senderID: 2, at: 1, clientGeneratedID: request.body.clientGeneratedId),
            try TimelineTestFixtures.message(id: "empty-id", at: 1, clientGeneratedID: "")
        ] {
            let handled = await h.queue.acceptAcknowledgement(invalid)
            XCTAssertFalse(handled)
        }
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").count, 1)
        let message = try response(request)
        await h.api.finish(0, with: .success(message))
        try await eventually { h.queue.pendingMessages(chatID: "chat").isEmpty }
        _ = await h.queue.acceptAcknowledgement(message)
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        await h.close()
        let store = try await h.openStore(uid: 1)
        let restored = try await store.restore()
        XCTAssertEqual(restored.flatMap(\.outgoing), [])
    }

    func testHistoryCanConfirmQueuedWorkWithoutDispatching() async throws {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        let pending = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let message = try TimelineTestFixtures.message(id: "history", at: 1, clientGeneratedID: pending.clientGeneratedID)
        let handled = await h.queue.acceptAcknowledgement(message)
        XCTAssertTrue(handled)
        await h.queue.setForegroundActive(true)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat"), [])
        let requests = await h.api.requests()
        XCTAssertEqual(requests.count, 0)
        await h.close()
    }

    func testSceneStopPreservesInterruptedWorkAndResumesIdenticalRequest() async throws {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        let first = try await firstRequest(h.api)
        h.queue.requestForegroundActive(false)
        await h.api.finish(0, with: .failure(CancellationError()))
        await h.queue.setForegroundActive(false)
        XCTAssertFalse(h.queue.pendingMessages(chatID: "chat").contains { $0.state == .failed })
        await h.queue.setForegroundActive(true)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests[0].body, requests[1].body)
        XCTAssertEqual(requests[1].body, first.body)
        await h.close()
    }

    func testAccountHandoffSynchronouslyInvalidatesOldHTTPCompletion() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "old account", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        let first = try await firstRequest(h.api)
        var receivedOld = false
        let observation = h.queue.events.sink {
            if case .acknowledged(_, let message) = $0, message.clientGeneratedId == first.body.clientGeneratedId { receivedOld = true }
        }
        h.queue.requestSession(uid: 2)
        XCTAssertEqual(h.queue.storageState, .loading)
        XCTAssertEqual(h.queue.snapshots, [:])
        await h.api.finish(0, with: .success(try response(first)))
        await h.queue.activate(uid: 2)
        XCTAssertFalse(receivedOld)
        XCTAssertEqual(h.queue.snapshots, [:])
        await h.queue.setForegroundActive(false)
        await h.queue.activate(uid: 1)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["old account"])
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.queued])
        observation.cancel()
        await h.close()
    }

    func testRestartResumesInterruptedRetryBatchBeforeEarlierFailure() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID, scope: .messageAndSubsequent)
        try await eventually { await h.api.requests().count == 2 }
        let firstRun = await h.api.requests()
        await h.close()
        let second = try await openHarness(root: h.root)
        try await eventually { await second.api.requests().count == 1 }
        var requests = await second.api.requests()
        XCTAssertEqual(requests[0].body, firstRun[1].body)
        await second.api.finish(0, with: .success(try response(requests[0])))
        try await eventually { await second.api.requests().count == 2 }
        requests = await second.api.requests()
        XCTAssertEqual(requests.map(\.body.message), ["B", "C"])
        await second.api.finish(1, with: .success(try response(requests[1])))
        try await eventually { second.queue.pendingMessages(chatID: "chat").map(\.text) == ["A"] }
        XCTAssertEqual(second.queue.pendingMessages(chatID: "chat").first?.state, .failed)
        await second.close()
    }

    func testEnqueueAndClaimStorageFailuresNeverSendUncommittedWork() async throws {
        let h = try await openHarness()
        try await h.queue.saveDraft(chatID: "chat", text: "hello\n世界", editRevision: 1, updatedAt: Date())
        h.faults.failures = [.enqueue]
        do {
            try await h.queue.enqueueText(chatID: "chat", text: "hello\n世界", clearedDraftRevision: 2)
            XCTFail("Enqueue must fail before committing")
        } catch {}
        XCTAssertEqual(h.queue.snapshots["chat"]?.draft.text, "hello\n世界")
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat"), [])
        var requests = await h.api.requests()
        XCTAssertEqual(requests.count, 0)
        h.faults.failures = []
        await h.queue.retryStorage()
        h.faults.failures = [.claim]
        try await h.queue.enqueueText(chatID: "chat", text: "hello\n世界", clearedDraftRevision: 2)
        try await eventually { h.queue.storageState == .failed }
        requests = await h.api.requests()
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.queued])
        h.faults.failures = []
        await h.queue.retryStorage()
        try await eventually { await h.api.requests().count == 1 }
        let resumed = await h.api.requests()
        XCTAssertEqual(resumed[0].body.message, "hello\n世界")
        await h.close()
    }

    func testAcknowledgementStorageFailureHidesDeliveryAndRecoversDeletionBeforeSuccessor() async throws {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        let first = try await firstRequest(h.api)
        let message = try response(first)
        var delivered: [String] = []
        let observation = h.queue.events.sink {
            if case .acknowledged(_, let response) = $0 { delivered.append(response.id) }
        }
        h.faults.failures = [.acknowledge]
        await h.api.finish(0, with: .success(message))
        try await eventually { h.queue.storageState == .failed && delivered == [message.id] }
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["B", "C"])
        try await h.queue.saveDraft(chatID: "chat", text: "new draft", editRevision: 4, updatedAt: Date())
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["B", "C"])
        let paused = await h.api.requests()
        XCTAssertEqual(paused.count, 1)
        h.faults.failures = []
        await h.queue.retryStorage()
        try await eventually { await h.api.requests().count == 2 }
        let resumed = await h.api.requests()
        XCTAssertEqual(resumed[1].body.message, "B")
        XCTAssertFalse(h.queue.snapshots["chat"]!.outgoing.contains { $0.clientGeneratedID == message.clientGeneratedId })
        observation.cancel()
        await h.close()
        let store = try await h.openStore(uid: 1)
        let restored = try await store.restore()
        XCTAssertFalse(restored.flatMap(\.outgoing).contains { $0.clientGeneratedID == message.clientGeneratedId })
    }

    func testFailedFailureCommitIsRetriedAsFailureNotAsAutomaticNetworkRetry() async throws {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        h.faults.failures = [.fail]
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually { h.queue.storageState == .failed }
        h.faults.failures = []
        await h.queue.retryStorage()
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.failed, .failed, .failed])
        let requests = await h.api.requests()
        XCTAssertEqual(requests.count, 1)
        await h.close()
    }

    func testStartupStorageFailureHasNoMemoryFallbackAndCanRetry() async throws {
        let h = try await openHarness(failRestore: true)
        XCTAssertEqual(h.queue.storageState, .failed)
        do {
            try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
            XCTFail("Unavailable storage cannot accept a send")
        } catch {}
        let requests = await h.api.requests()
        XCTAssertEqual(requests.count, 0)
        h.faults.failures = []
        await h.queue.retryStorage()
        XCTAssertEqual(h.queue.storageState, .ready)
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        await h.close()
    }

    func testInvalidTokenPersistsFailureBeforeEndingSessionAndStopsAccountWork() async throws {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        await h.api.finish(0, with: .failure(APIError.invalidToken))
        try await eventually { h.invalidTokenStates != nil }
        XCTAssertEqual(h.invalidTokenStates, [.failed, .failed, .failed])
        await h.queue.setForegroundActive(false)
        await h.queue.setForegroundActive(true)
        let requests = await h.api.requests()
        XCTAssertEqual(requests.count, 1)
        await h.close()
    }

    func testFailedRowsStayPausedAcrossRelaunchAndForegroundTransitions() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        await h.close()
        let reopened = try await openHarness(root: h.root)
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "chat").map(\.state), [.failed, .failed, .failed])
        await reopened.queue.setForegroundActive(false)
        await reopened.queue.setForegroundActive(true)
        let requests = await reopened.api.requests()
        XCTAssertEqual(requests.count, 0)
        try await reopened.queue.retry(chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID, scope: .message)
        try await eventually { await reopened.api.requests().count == 1 }
        let retried = try await firstRequest(reopened.api)
        XCTAssertEqual(retried.body.clientGeneratedId, rows[1].clientGeneratedID)
        XCTAssertEqual(retried.body.message, "B")
        await reopened.close()
    }

    func testImmediateSameAccountReactivationWaitsForPriorWorkerBeforeRestore() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        let original = try await firstRequest(h.api)
        h.queue.requestSession(uid: nil)
        h.queue.requestSession(uid: 1)
        XCTAssertEqual(h.queue.storageState, .loading)
        XCTAssertEqual(h.queue.snapshots, [:])
        await h.api.finish(0, with: .failure(CancellationError()))
        await h.queue.activate(uid: 1)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests[1].body, original.body)
        let concurrency = await h.api.maximumConcurrency(chatID: "chat")
        XCTAssertEqual(concurrency, 1)
        XCTAssertFalse(h.queue.pendingMessages(chatID: "chat").contains { $0.state == .failed })
        await h.close()
    }

    private func enqueueABC(_ h: Harness) async throws -> [LocalOutgoingMessage] {
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        try await h.queue.enqueueText(chatID: "chat", text: "B", clearedDraftRevision: 2)
        try await h.queue.enqueueText(chatID: "chat", text: "C", clearedDraftRevision: 3)
        return h.queue.pendingMessages(chatID: "chat")
    }

    private func pausedABC(_ h: Harness) async throws -> [LocalOutgoingMessage] {
        let rows = try await enqueueABC(h)
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually { h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .failed, .failed] }
        return rows
    }

    private func response(_ request: HeldQueueAPI.Request) throws -> MessageResponse {
        try TimelineTestFixtures.message(id: "server-\(request.body.clientGeneratedId)", chatID: request.chatID, at: 1, clientGeneratedID: request.body.clientGeneratedId)
    }

    private func eventually(_ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out awaiting queue transition", file: file, line: line)
                throw QueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func firstRequest(_ api: HeldQueueAPI) async throws -> HeldQueueAPI.Request {
        let requests = await api.requests()
        return try XCTUnwrap(requests.first)
    }

    private func openHarness(root: URL? = nil, foreground: Bool = true, failRestore: Bool = false) async throws -> Harness {
        let harness = try await Harness.open(root: root, foreground: foreground, failRestore: failRestore)
        addTeardownBlock {
            await harness.close()
            if root == nil {
                try FileManager.default.removeItem(at: harness.root)
            }
        }
        return harness
    }
}

@MainActor
private final class QueueStorageFaults {
    var failures: [OutgoingMessageQueue.StorageOperation] = []
    func check(_ operation: OutgoingMessageQueue.StorageOperation) throws {
        if failures.contains(operation) { throw QueueTestError.storage }
    }
}

@MainActor
private final class Harness {
    let root: URL
    let api = HeldQueueAPI()
    let faults = QueueStorageFaults()
    var queue: OutgoingMessageQueue!
    var invalidTokenStates: [LocalOutgoingMessage.State]?

    private init(root: URL) {
        self.root = root
        queue = OutgoingMessageQueue(
            apiClient: api,
            localStoreFactory: { uid in
                try await Task.detached {
                    let scope = LocalStorageScope(apiBaseURL: URL(string: "https://queue.invalid/api")!, userID: uid)
                    return try ChahuaLocalStore(directory: scope.directory(under: root))
                }.value
            },
            onInvalidToken: { [weak self] in
                self?.invalidTokenStates = self?.queue.pendingMessages(chatID: "chat").map(\.state)
            },
            beforeStorageOperation: { [faults] operation in try faults.check(operation) }
        )
    }

    static func open(root: URL? = nil, foreground: Bool = true, failRestore: Bool = false) async throws -> Harness {
        let harness = Harness(root: root ?? FileManager.default.temporaryDirectory.appendingPathComponent("OutgoingQueue-\(UUID().uuidString)"))
        if failRestore { harness.faults.failures = [.restore] }
        await harness.queue.activate(uid: 1)
        await harness.queue.setForegroundActive(foreground)
        return harness
    }

    func openStore(uid: Int32) async throws -> ChahuaLocalStore {
        let root = root
        return try await Task.detached {
            let scope = LocalStorageScope(apiBaseURL: URL(string: "https://queue.invalid/api")!, userID: uid)
            return try ChahuaLocalStore(directory: scope.directory(under: root))
        }.value
    }

    func close() async {
        queue.requestSession(uid: nil)
        await api.finishAll()
        await queue.deactivate()
    }
}

private enum QueueTestError: Error { case network, storage, timeout }

private actor HeldQueueAPI: ChahuaAPIClient {
    struct Request: Sendable {
        let chatID: String
        let body: CreateMessageBody
    }

    private var recorded: [Request] = []
    private var held: [Int: CheckedContinuation<MessageResponse, Error>] = [:]
    private var active: [String: Int] = [:]
    private var maximum: [String: Int] = [:]

    func authenticate(candidateJWT: String) async throws -> MeResponse { throw APIError.unavailable }
    func createDevSession(uid: Int32, clientID: String) async throws -> String { throw APIError.unavailable }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse { throw APIError.unavailable }
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse { throw APIError.unavailable }
    func groupInfo(chatID: String) async throws -> GroupInfoResponse { throw APIError.unavailable }
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse { throw APIError.unavailable }
    func getMessage(chatID: String, messageID: String) async throws -> MessageResponse { throw APIError.unavailable }
    func putReaction(chatID: String, messageID: String, emoji: String) async throws { throw APIError.unavailable }
    func deleteReaction(chatID: String, messageID: String, emoji: String) async throws { throw APIError.unavailable }

    // Intentionally ignores cancellation until explicitly completed, exercising late responses.
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse {
        let index = recorded.count
        recorded.append(Request(chatID: chatID, body: body))
        active[chatID, default: 0] += 1
        maximum[chatID] = max(maximum[chatID, default: 0], active[chatID, default: 0])
        return try await withCheckedThrowingContinuation { held[index] = $0 }
    }

    func requests() -> [Request] { recorded }
    func maximumConcurrency(chatID: String) -> Int { maximum[chatID, default: 0] }

    func finish(_ index: Int, with result: Result<MessageResponse, Error>) {
        guard let continuation = held.removeValue(forKey: index) else { return }
        active[recorded[index].chatID, default: 0] -= 1
        continuation.resume(with: result)
    }

    func finishAll() {
        for index in Array(held.keys) { finish(index, with: .failure(CancellationError())) }
    }
}
