import Foundation
import XCTest
@testable import ChahuaAPI

final class LocalPersistenceTests: XCTestCase {
    func testDraftHandoffRollbackAndAccountIsolationAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = LocalStorageScope(apiBaseURL: URL(string: "https://example.com/api")!, userID: 1)
        let directory = scope.directory(under: root)
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        _ = try await store!.saveDraft(chatID: "chat", text: "hello\n世界", editRevision: 1, updatedAt: Date())
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        XCTAssertEqual(restored.first?.draft.text, "hello\n世界")
        let sent = try await store!.enqueueText(chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "  hello\n世界  ", enqueuedAt: Date(), clearedDraftRevision: 2)
        XCTAssertEqual(sent.draft.text, "")
        XCTAssertEqual(sent.outgoing.map(\.text), ["hello\n世界"])
        let late = try await store!.saveDraft(chatID: "chat", text: "stale", editRevision: 1, updatedAt: Date())
        XCTAssertEqual(late.draft.text, "")
        _ = try await store!.saveDraft(chatID: "chat", text: "keep me", editRevision: 3, updatedAt: Date())
        do {
            _ = try await store!.enqueueText(chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "duplicate", enqueuedAt: Date(), clearedDraftRevision: 4)
            XCTFail("Duplicate identity must roll back the entire handoff")
        } catch { }
        let rolledBack = try await store!.restore()
        XCTAssertEqual(rolledBack.first?.draft.text, "keep me")
        XCTAssertEqual(rolledBack.first?.outgoing.map(\.clientGeneratedID), ["A"])
        let otherChat = try await store!.saveDraft(chatID: "other", text: "", editRevision: 1, updatedAt: Date())
        XCTAssertTrue(otherChat.outgoing.isEmpty)
        for otherScope in [LocalStorageScope(apiBaseURL: scope.apiBaseURL, userID: 2), LocalStorageScope(apiBaseURL: URL(string: "https://example.com/other")!, userID: 1)] {
            let isolated = try ChahuaLocalStore(directory: otherScope.directory(under: root))
            let snapshots = try await isolated.restore()
            XCTAssertTrue(snapshots.isEmpty)
        }
    }

    func testFailureRetryOrderingAndInterruptedRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        for (index, id) in ["A", "B", "C"].enumerated() {
            _ = try await store!.enqueueText(chatID: "chat", senderID: 1, clientGeneratedID: id, text: id, enqueuedAt: Date(timeIntervalSince1970: Double(index)), clearedDraftRevision: Int64(index + 1))
        }
        let claimed = try await store!.claimNext(chatID: "chat")
        XCTAssertEqual(claimed.message?.clientGeneratedID, "A")
        let duplicateClaim = try await store!.claimNext(chatID: "chat")
        XCTAssertNil(duplicateClaim.message)
        let failed = try await store!.fail(chatID: "chat", clientGeneratedID: "A")
        XCTAssertEqual(failed.outgoing.map(\.state), [.failed, .failed, .failed])
        let paused = try await store!.enqueueText(chatID: "chat", senderID: 1, clientGeneratedID: "D", text: "D", enqueuedAt: Date(), clearedDraftRevision: 4)
        XCTAssertEqual(paused.outgoing.last?.state, .failed)
        let retry = try await store!.retry(chatID: "chat", clientGeneratedID: "B", scope: .messageAndSubsequent)
        XCTAssertEqual(retry.outgoing.map(\.clientGeneratedID), ["B", "C", "D", "A"])
        XCTAssertEqual(retry.outgoing.map(\.state), [.queued, .queued, .queued, .failed])
        XCTAssertEqual(retry.outgoing.first?.enqueuedAt, failed.outgoing[1].enqueuedAt)
        XCTAssertEqual(retry.outgoing.first?.enqueueSequence, failed.outgoing[1].enqueueSequence)
        _ = try await store!.claimNext(chatID: "chat")
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        XCTAssertEqual(restored.first?.outgoing.map(\.state), [.queued, .queued, .queued, .failed])
        let next = try await store!.claimNext(chatID: "chat")
        XCTAssertEqual(next.message?.clientGeneratedID, "B")
        _ = try await store!.acknowledge(chatID: "chat", clientGeneratedID: "B")
        let obsoleteFailure = try await store!.fail(chatID: "chat", clientGeneratedID: "B")
        XCTAssertEqual(obsoleteFailure.outgoing.map(\.state), [.queued, .queued, .failed])
        _ = try await store!.fail(chatID: "chat", clientGeneratedID: "C")
        let single = try await store!.retry(chatID: "chat", clientGeneratedID: "D", scope: .message)
        XCTAssertEqual(single.outgoing.map(\.clientGeneratedID), ["D", "C", "A"])
        XCTAssertEqual(single.outgoing.map(\.state), [.queued, .failed, .failed])
    }
}
