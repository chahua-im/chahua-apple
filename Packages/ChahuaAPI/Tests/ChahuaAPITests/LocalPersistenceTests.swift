import Foundation
import GRDB
import XCTest
@testable import ChahuaAPI

final class LocalPersistenceTests: XCTestCase {
    func testLegacyParentDraftAndOutboxMigrateWithoutLosingOrderOrRevisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let legacy = try DatabaseQueue(path: directory.appendingPathComponent("chat.sqlite").path)
            try await legacy.write { db in
                try db.execute(sql: """
                    CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
                    INSERT INTO grdb_migrations VALUES ('v1_drafts_outbox');
                    CREATE TABLE local_conversation (
                        chat_id TEXT PRIMARY KEY NOT NULL,
                        revision INTEGER NOT NULL DEFAULT 0,
                        next_enqueue_sequence INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE TABLE draft (
                        chat_id TEXT PRIMARY KEY NOT NULL REFERENCES local_conversation(chat_id),
                        text TEXT NOT NULL, edit_revision INTEGER NOT NULL, updated_at REAL NOT NULL
                    );
                    CREATE TABLE outgoing_message (
                        client_generated_id TEXT PRIMARY KEY NOT NULL,
                        chat_id TEXT NOT NULL REFERENCES local_conversation(chat_id),
                        sender_id INTEGER NOT NULL, text TEXT NOT NULL, enqueued_at REAL NOT NULL,
                        enqueue_sequence INTEGER NOT NULL, dispatch_order INTEGER NOT NULL,
                        state TEXT NOT NULL CHECK(state IN ('queued','sending','failed')),
                        UNIQUE(chat_id, enqueue_sequence)
                    );
                    CREATE INDEX outgoing_dispatch ON outgoing_message(chat_id, dispatch_order);
                    INSERT INTO local_conversation VALUES ('chat', 7, 2);
                    INSERT INTO draft VALUES ('chat', 'unsent 世界', 5, 123);
                    INSERT INTO outgoing_message VALUES ('A', 'chat', 1, 'first', 100, 0, 1, 'failed');
                    INSERT INTO outgoing_message VALUES ('B', 'chat', 1, 'retry', 101, 1, 0, 'sending');
                    """)
            }
        }
        let store = try ChahuaLocalStore(directory: directory)
        let restored = try await store.restore()
        let parent = try XCTUnwrap(restored.first)
        XCTAssertEqual(parent.conversationKey, ConversationKey(chatID: "chat"))
        XCTAssertEqual(parent.draft.text, "unsent 世界")
        XCTAssertEqual(parent.draft.editRevision, 5)
        XCTAssertEqual(parent.draft.updatedAt, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(parent.revision, 8)
        XCTAssertEqual(parent.outgoing.map(\.clientGeneratedID), ["B", "A"])
        XCTAssertEqual(parent.outgoing.map(\.state), [.queued, .failed])
        XCTAssertEqual(parent.outgoing.map(\.enqueueSequence), [1, 0])
        _ = try await store.saveDraft(chatID: "chat", threadID: "root", text: "thread", editRevision: 1, updatedAt: Date())
        let stale = try await store.saveDraft(chatID: "chat", text: "stale", editRevision: 4, updatedAt: Date())
        XCTAssertEqual(stale.draft.text, "unsent 世界")
        let queued = try await store.enqueueText(chatID: "chat", senderID: 1, clientGeneratedID: "C", text: "next", enqueuedAt: Date(), clearedDraftRevision: 6)
        XCTAssertEqual(queued.outgoing.last?.enqueueSequence, 2)
        XCTAssertEqual(queued.outgoing.last?.state, .failed)
    }

    func testThreadDraftFailureRetryAndAcknowledgementStayIsolatedAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let keys = [ConversationKey(chatID: "chat"), ConversationKey(chatID: "chat", threadID: "one"), ConversationKey(chatID: "chat", threadID: "two")]
        for (index, key) in keys.enumerated() {
            _ = try await store!.enqueueText(chatID: key.chatID, threadID: key.threadID, senderID: 1, clientGeneratedID: "id-\(index)", text: "outgoing-\(index)", enqueuedAt: Date(), clearedDraftRevision: 1)
            _ = try await store!.saveDraft(chatID: key.chatID, threadID: key.threadID, text: "draft-\(index)", editRevision: 2, updatedAt: Date())
        }
        _ = try await store!.fail(chatID: "chat", threadID: "one", clientGeneratedID: "id-1")
        _ = try await store!.claimNext(chatID: "chat", threadID: "two")
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        let snapshots = Dictionary(uniqueKeysWithValues: restored.map { ($0.conversationKey, $0) })
        for (index, key) in keys.enumerated() {
            XCTAssertEqual(snapshots[key]?.draft.text, "draft-\(index)")
            XCTAssertEqual(snapshots[key]?.outgoing.map(\.clientGeneratedID), ["id-\(index)"])
            XCTAssertEqual(snapshots[key]?.outgoing.first?.conversationKey, key)
        }
        XCTAssertEqual(snapshots[keys[0]]?.outgoing.first?.state, .queued)
        XCTAssertEqual(snapshots[keys[1]]?.outgoing.first?.state, .failed)
        XCTAssertEqual(snapshots[keys[2]]?.outgoing.first?.state, .queued)
        _ = try await store!.retry(chatID: "chat", clientGeneratedID: "id-1", scope: .messageAndSubsequent)
        let stillFailed = try await store!.claimNext(chatID: "chat", threadID: "one")
        XCTAssertNil(stillFailed.message)
        _ = try await store!.retry(chatID: "chat", threadID: "one", clientGeneratedID: "id-1", scope: .messageAndSubsequent)
        let retry = try await store!.claimNext(chatID: "chat", threadID: "one")
        XCTAssertEqual(retry.message?.clientGeneratedID, "id-1")
        _ = try await store!.acknowledge(chatID: "chat", clientGeneratedID: "id-1")
        let wrongAcknowledgement = try await store!.claimNext(chatID: "chat", threadID: "one")
        XCTAssertEqual(wrongAcknowledgement.snapshot.outgoing.map(\.clientGeneratedID), ["id-1"])
        let acknowledged = try await store!.acknowledge(chatID: "chat", threadID: "one", clientGeneratedID: "id-1")
        XCTAssertTrue(acknowledged.outgoing.isEmpty)
        XCTAssertEqual(acknowledged.draft.text, "draft-1")
        let parent = try await store!.claimNext(chatID: "chat")
        let otherThread = try await store!.claimNext(chatID: "chat", threadID: "two")
        XCTAssertEqual(parent.message?.clientGeneratedID, "id-0")
        XCTAssertEqual(otherThread.message?.clientGeneratedID, "id-2")
    }

    func testDraftHandoffRollbackAndAccountIsolationAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = LocalStorageScope(apiBaseURL: URL(string: "https://example.com/api")!, userID: 1)
        let directory = scope.directory(under: root)
        let reply = preview(id: "original")
        let nextReply = preview(id: "next")
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        _ = try await store!.saveDraft(chatID: "chat", text: "hello\n世界", editRevision: 1, updatedAt: Date(), replyToMessage: reply)
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        XCTAssertEqual(restored.first?.draft.text, "hello\n世界")
        XCTAssertEqual(restored.first?.draft.replyToMessage, reply)
        let sent = try await store!.enqueueText(chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "  hello\n世界  ", enqueuedAt: Date(), clearedDraftRevision: 2, replyToMessage: reply)
        XCTAssertEqual(sent.draft.text, "")
        XCTAssertNil(sent.draft.replyToMessage)
        XCTAssertEqual(sent.outgoing.first?.replyToMessage, reply)
        XCTAssertEqual(sent.outgoing.map(\.text), ["hello\n世界"])
        let late = try await store!.saveDraft(chatID: "chat", text: "stale", editRevision: 1, updatedAt: Date(), replyToMessage: reply)
        XCTAssertEqual(late.draft.text, "")
        XCTAssertNil(late.draft.replyToMessage)
        _ = try await store!.saveDraft(chatID: "chat", text: "keep me", editRevision: 3, updatedAt: Date(), replyToMessage: nextReply)
        do {
            _ = try await store!.enqueueText(chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "duplicate", enqueuedAt: Date(), clearedDraftRevision: 4, replyToMessage: nextReply)
            XCTFail("Duplicate identity must roll back the entire handoff")
        } catch { }
        let rolledBack = try await store!.restore()
        XCTAssertEqual(rolledBack.first?.draft.text, "keep me")
        XCTAssertEqual(rolledBack.first?.draft.replyToMessage, nextReply)
        XCTAssertEqual(rolledBack.first?.outgoing.first?.replyToMessage, reply)
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

    private func preview(id: String) -> MessagePreview {
        MessagePreview(
            id: id, clientGeneratedId: "client-\(id)", createdAt: Date(timeIntervalSince1970: 1),
            sender: User(uid: 2, gender: 0, name: "Ada", avatarUrl: nil, userGroup: nil),
            messageType: .text, attachments: [], mentions: [], isDeleted: false,
            message: "Reply to \(id)", sticker: nil
        )
    }
}
