import Foundation
import GRDB
import XCTest

@testable import ChahuaAPI

final class LocalPersistenceTests: XCTestCase {
    func testStickerEnqueuePreservesCompositionAndDispatchesBeforeItsAttachmentsAcrossReopen()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let begun = try await store!.beginComposition(
            chatID: "chat", threadID: "thread", senderID: 1)
        let composition = try XCTUnwrap(begun.composingItem)
        let slot = try attachment(directory: directory, id: "image", position: 0)
        let attached = try await store!.setCompositionAttachments(
            chatID: "chat", threadID: "thread", itemID: composition.clientGeneratedID,
            expectedRevision: composition.editRevision, attachments: [slot],
            compressionEnabled: false)
        let saved = try await store!.saveDraft(
            chatID: "chat", threadID: "thread", text: "keep this draft",
            editRevision: attached.draft.editRevision + 1, updatedAt: Date(),
            replyToMessage: preview(id: "draft-reply"))
        let sticker = MessageStickerResponse(
            id: "sticker", emoji: "wave", createdAt: Date(timeIntervalSince1970: 1),
            isFavorited: true,
            media: MessageStickerMediaResponse(
                id: "media", url: "https://example.test/sticker.webp",
                contentType: "image/webp", size: 123, width: 200, height: 150),
            name: "Wave", description: "A wave")
        let reply = preview(id: "sticker-reply")
        let enqueued = try await store!.enqueueSticker(
            chatID: "chat", threadID: "thread", senderID: 1, clientGeneratedID: "selected-sticker",
            sticker: sticker, enqueuedAt: Date(timeIntervalSince1970: 2), replyToMessage: reply)
        XCTAssertEqual(enqueued.draft, saved.draft)
        XCTAssertEqual(enqueued.composingItem?.clientGeneratedID, composition.clientGeneratedID)
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        XCTAssertEqual(restored.first?.draft, saved.draft)
        XCTAssertEqual(restored.first?.outgoing.first?.sticker, sticker)
        let claim = try await store!.claimNext(chatID: "chat", threadID: "thread")
        XCTAssertEqual(
            claim.message?.body,
            CreateMessageBody(
                messageType: .sticker, clientGeneratedId: "selected-sticker", replyToId: reply.id,
                stickerId: sticker.id))
        XCTAssertEqual(claim.message?.replyToMessage, reply)
        let acknowledged = try await store!.acknowledge(
            chatID: "chat", threadID: "thread", clientGeneratedID: "selected-sticker")
        XCTAssertTrue(acknowledged.outgoing.isEmpty)
        XCTAssertEqual(acknowledged.draft, saved.draft)

        var uploaded = try XCTUnwrap(acknowledged.composingItem?.attachments.first)
        uploaded.attachmentID = "uploaded-image"
        _ = try await store!.checkpointAttachment(
            chatID: "chat", threadID: "thread", itemID: composition.clientGeneratedID,
            attachment: uploaded)
        _ = try await store!.enqueueText(
            chatID: "chat", threadID: "thread", senderID: 1, clientGeneratedID: "unused",
            text: saved.draft.text, enqueuedAt: Date(),
            clearedDraftRevision: saved.draft.editRevision + 1,
            replyToMessage: saved.draft.replyToMessage)
        let imageClaim = try await store!.claimNext(chatID: "chat", threadID: "thread")
        XCTAssertEqual(imageClaim.message?.body.messageType, .text)
        XCTAssertEqual(imageClaim.message?.body.message, "keep this draft")
        XCTAssertEqual(imageClaim.message?.body.attachmentIds, ["uploaded-image"])
        XCTAssertEqual(imageClaim.message?.body.replyToId, "draft-reply")
        XCTAssertNil(imageClaim.message?.body.stickerId)
    }

    func testStickerCannotBecomeTextCompositionButCanBeRevokedBeforeDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let sticker = MessageStickerResponse(
            id: "sticker", emoji: "wave", createdAt: Date(timeIntervalSince1970: 1),
            isFavorited: nil,
            media: MessageStickerMediaResponse(
                id: "media", url: "https://example.test/sticker.webp",
                contentType: "image/webp", size: 123, width: nil, height: nil),
            name: nil, description: nil)
        _ = try await store.enqueueSticker(
            chatID: "chat", senderID: 1, clientGeneratedID: "sticker-send",
            sticker: sticker, enqueuedAt: Date())
        do {
            _ = try await store.blockTail(
                chatID: "chat", itemID: "sticker-send", expectedRevision: 0)
            XCTFail("A sticker must not be converted into an empty text draft")
        } catch LocalStorageError.unsupportedMessageType {}
        let restored = try await store.restore()
        XCTAssertNil(restored.first?.composingItem)
        XCTAssertEqual(restored.first?.outgoing.first?.body.messageType, .sticker)
        let revoked = try await store.revokeTail(
            chatID: "chat", itemID: "sticker-send", expectedRevision: 0)
        XCTAssertTrue(revoked.outgoing.isEmpty)
        let claim = try await store.claimNext(chatID: "chat")
        XCTAssertNil(claim.message)
    }

    func testLegacyDraftMigrationPreservesIdentityRevisionsAndRestoresFIFO() async throws {
        try await assertLegacyDraftMigration(hasReplyContext: false)
    }

    func testLegacyReplyContextMigrationPreservesDraftAndQueuedReplies() async throws {
        try await assertLegacyDraftMigration(hasReplyContext: true)
    }

    private func assertLegacyDraftMigration(hasReplyContext: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reply = hasReplyContext ? preview(id: "quoted") : nil
        let replyData = try reply.map { try JSONEncoder().encode($0) }
        do {
            let legacy = try DatabaseQueue(
                path: directory.appendingPathComponent("chat.sqlite").path)
            try await legacy.write { db in
                try db.execute(
                    sql: """
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
                if let replyData {
                    try db.execute(
                        sql: """
                            ALTER TABLE draft ADD COLUMN reply_to_message BLOB;
                            ALTER TABLE outgoing_message ADD COLUMN reply_to_message BLOB;
                            INSERT INTO grdb_migrations VALUES ('v2_reply_context');
                            """)
                    try db.execute(
                        sql: "UPDATE draft SET reply_to_message = ?", arguments: [replyData])
                    try db.execute(
                        sql: "UPDATE outgoing_message SET reply_to_message = ?",
                        arguments: [replyData])
                }
            }
        }
        let store = try ChahuaLocalStore(directory: directory)
        let restored = try await store.restore()
        let parent = try XCTUnwrap(restored.first)
        XCTAssertEqual(parent.conversationKey, ConversationKey(chatID: "chat"))
        XCTAssertEqual(parent.draft.text, "unsent 世界")
        XCTAssertEqual(parent.draft.editRevision, 5)
        XCTAssertEqual(parent.draft.updatedAt, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(parent.draft.replyToMessage, reply)
        XCTAssertEqual(parent.outgoing.map(\.replyToMessage), [reply, reply])
        XCTAssertEqual(parent.revision, 8)
        XCTAssertEqual(parent.outgoing.map(\.clientGeneratedID), ["A", "B"])
        XCTAssertEqual(parent.outgoing.map(\.state), [.failed, .queued])
        XCTAssertEqual(parent.outgoing.map(\.enqueueSequence), [0, 1])
        XCTAssertTrue(parent.outgoing.allSatisfy(\.dispatchClaimed))
        let composingID = try XCTUnwrap(parent.composingItem?.clientGeneratedID)
        XCTAssertEqual(parent.draft.itemID, composingID)
        _ = try await store.saveDraft(
            chatID: "chat", threadID: "root", text: "thread", editRevision: 1, updatedAt: Date())
        let stale = try await store.saveDraft(
            chatID: "chat", text: "stale", editRevision: 4, updatedAt: Date())
        XCTAssertEqual(stale.draft.text, "unsent 世界")
        let queued = try await store.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "C", text: "next", enqueuedAt: Date(),
            clearedDraftRevision: 6)
        XCTAssertEqual(queued.outgoing.last?.enqueueSequence, 2)
        XCTAssertEqual(queued.outgoing.last?.state, .queued)
        XCTAssertEqual(queued.outgoing.last?.clientGeneratedID, composingID)
        XCTAssertNil(queued.composingItem)
        XCTAssertEqual(queued.draft.text, "")
        let blockedByFailure = try await store.claimNext(chatID: "chat")
        XCTAssertNil(blockedByFailure.message)
    }

    func testThreadSchemaWithoutLegacyMigrationIdentityReopensWithoutLosingReplies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reply = preview(id: "quoted")
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        _ = try await store!.enqueueText(
            chatID: "chat", threadID: "thread", senderID: 1, clientGeneratedID: "queued",
            text: "outgoing", enqueuedAt: Date(), clearedDraftRevision: 1, replyToMessage: reply)
        let saved = try await store!.saveDraft(
            chatID: "chat", threadID: "thread", text: "draft", editRevision: 2,
            updatedAt: Date(), replyToMessage: reply)
        store = nil
        do {
            let database = try DatabaseQueue(
                path: directory.appendingPathComponent("chat.sqlite").path)
            try await database.write { db in
                // The thread-first release never registered the earlier reply migration.
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2_reply_context'")
            }
        }
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        XCTAssertEqual(restored, [saved])
        store = nil
        do {
            let database = try DatabaseQueue(
                path: directory.appendingPathComponent("chat.sqlite").path)
            try await database.write { db in
                try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('unknown_future_schema')")
            }
        }
        XCTAssertThrowsError(try ChahuaLocalStore(directory: directory)) { error in
            guard case LocalStorageError.unsupportedSchema = error else {
                return XCTFail("An unknown future schema must still be rejected: \(error)")
            }
        }
    }

    func testThreadDraftFailureRetryAndAcknowledgementStayIsolatedAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let keys = [
            ConversationKey(chatID: "chat"), ConversationKey(chatID: "chat", threadID: "one"),
            ConversationKey(chatID: "chat", threadID: "two"),
        ]
        for (index, key) in keys.enumerated() {
            _ = try await store!.enqueueText(
                chatID: key.chatID, threadID: key.threadID, senderID: 1,
                clientGeneratedID: "id-\(index)", text: "outgoing-\(index)", enqueuedAt: Date(),
                clearedDraftRevision: 1)
            _ = try await store!.saveDraft(
                chatID: key.chatID, threadID: key.threadID, text: "draft-\(index)", editRevision: 2,
                updatedAt: Date())
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
        _ = try await store!.retry(
            chatID: "chat", clientGeneratedID: "id-1", scope: .messageAndSubsequent)
        let stillFailed = try await store!.claimNext(chatID: "chat", threadID: "one")
        XCTAssertNil(stillFailed.message)
        _ = try await store!.retry(
            chatID: "chat", threadID: "one", clientGeneratedID: "id-1", scope: .messageAndSubsequent
        )
        let retry = try await store!.claimNext(chatID: "chat", threadID: "one")
        XCTAssertEqual(retry.message?.clientGeneratedID, "id-1")
        _ = try await store!.acknowledge(chatID: "chat", clientGeneratedID: "id-1")
        let wrongAcknowledgement = try await store!.claimNext(chatID: "chat", threadID: "one")
        XCTAssertEqual(wrongAcknowledgement.snapshot.outgoing.map(\.clientGeneratedID), ["id-1"])
        let acknowledged = try await store!.acknowledge(
            chatID: "chat", threadID: "one", clientGeneratedID: "id-1")
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
        let scope = LocalStorageScope(
            apiBaseURL: URL(string: "https://example.com/api")!, userID: 1)
        let directory = scope.directory(under: root)
        let reply = preview(id: "original")
        let nextReply = preview(id: "next")
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        _ = try await store!.saveDraft(
            chatID: "chat", text: "hello\n世界", editRevision: 1, updatedAt: Date(),
            replyToMessage: reply)
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        XCTAssertEqual(restored.first?.draft.text, "hello\n世界")
        XCTAssertEqual(restored.first?.draft.replyToMessage, reply)
        let originalID = try XCTUnwrap(restored.first?.draft.itemID)
        let sent = try await store!.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "  hello\n世界  ",
            enqueuedAt: Date(), clearedDraftRevision: 2, replyToMessage: reply)
        XCTAssertEqual(sent.draft.text, "")
        XCTAssertNil(sent.draft.replyToMessage)
        XCTAssertEqual(sent.outgoing.first?.replyToMessage, reply)
        XCTAssertEqual(sent.outgoing.map(\.text), ["hello\n世界"])
        let late = try await store!.saveDraft(
            chatID: "chat", text: "stale", editRevision: 1, updatedAt: Date(), replyToMessage: reply
        )
        XCTAssertEqual(late.draft.text, "")
        XCTAssertNil(late.draft.replyToMessage)
        _ = try await store!.saveDraft(
            chatID: "chat", text: "keep me", editRevision: 3, updatedAt: Date(),
            replyToMessage: nextReply)
        do {
            _ = try await store!.enqueueText(
                chatID: "chat", senderID: 1, clientGeneratedID: "unused", text: "stale release",
                enqueuedAt: Date(), clearedDraftRevision: 3, replyToMessage: nextReply)
            XCTFail("A stale release must roll back the entire handoff")
        } catch {}
        let rolledBack = try await store!.restore()
        XCTAssertEqual(rolledBack.first?.draft.text, "keep me")
        XCTAssertEqual(rolledBack.first?.draft.replyToMessage, nextReply)
        XCTAssertEqual(rolledBack.first?.outgoing.first?.replyToMessage, reply)
        XCTAssertEqual(rolledBack.first?.outgoing.map(\.clientGeneratedID), [originalID])
        let otherChat = try await store!.saveDraft(
            chatID: "other", text: "", editRevision: 1, updatedAt: Date())
        XCTAssertTrue(otherChat.outgoing.isEmpty)
        for otherScope in [
            LocalStorageScope(apiBaseURL: scope.apiBaseURL, userID: 2),
            LocalStorageScope(apiBaseURL: URL(string: "https://example.com/other")!, userID: 1),
        ] {
            let isolated = try ChahuaLocalStore(directory: otherScope.directory(under: root))
            let snapshots = try await isolated.restore()
            XCTAssertTrue(snapshots.isEmpty)
        }
    }

    func testFailureRetryOrderingAndInterruptedRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        for (index, id) in ["A", "B", "C"].enumerated() {
            _ = try await store!.enqueueText(
                chatID: "chat", senderID: 1, clientGeneratedID: id, text: id,
                enqueuedAt: Date(timeIntervalSince1970: Double(index)),
                clearedDraftRevision: Int64(index + 1))
        }
        let claimed = try await store!.claimNext(chatID: "chat")
        XCTAssertEqual(claimed.message?.clientGeneratedID, "A")
        let duplicateClaim = try await store!.claimNext(chatID: "chat")
        XCTAssertNil(duplicateClaim.message)
        let failed = try await store!.fail(chatID: "chat", clientGeneratedID: "A")
        XCTAssertEqual(failed.outgoing.map(\.state), [.failed, .queued, .queued])
        let paused = try await store!.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "D", text: "D", enqueuedAt: Date(),
            clearedDraftRevision: 4)
        XCTAssertEqual(paused.outgoing.last?.state, .queued)
        _ = try await store!.fail(chatID: "chat", clientGeneratedID: "B")
        let retry = try await store!.retry(
            chatID: "chat", clientGeneratedID: "B", scope: .messageAndSubsequent)
        XCTAssertEqual(retry.outgoing.map(\.clientGeneratedID), ["A", "B", "C", "D"])
        XCTAssertEqual(retry.outgoing.map(\.state), [.failed, .queued, .queued, .queued])
        XCTAssertEqual(retry.outgoing[1].enqueuedAt, failed.outgoing[1].enqueuedAt)
        XCTAssertEqual(retry.outgoing[1].enqueueSequence, failed.outgoing[1].enqueueSequence)
        let waiting = try await store!.claimNext(chatID: "chat")
        XCTAssertNil(waiting.message)
        _ = try await store!.retry(chatID: "chat", clientGeneratedID: "A", scope: .message)
        let reclaimed = try await store!.claimNext(chatID: "chat")
        XCTAssertEqual(reclaimed.message?.body, claimed.message?.body)
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        XCTAssertEqual(restored.first?.outgoing.map(\.state), [.queued, .queued, .queued, .queued])
        XCTAssertEqual(restored.first?.outgoing.first?.dispatchClaimed, true)
        let next = try await store!.claimNext(chatID: "chat")
        XCTAssertEqual(next.message?.clientGeneratedID, "A")
        _ = try await store!.acknowledge(chatID: "chat", clientGeneratedID: "A")
        let obsoleteFailure = try await store!.fail(chatID: "chat", clientGeneratedID: "A")
        XCTAssertEqual(obsoleteFailure.outgoing.map(\.state), [.queued, .queued, .queued])
        let second = try await store!.claimNext(chatID: "chat")
        XCTAssertEqual(second.message?.clientGeneratedID, "B")
    }

    func testReleaseRetainsOrderedCheckpointsAndWaitsForEveryUploadAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let begun = try await store!.beginComposition(chatID: "chat", senderID: 1)
        let item = try XCTUnwrap(begun.composingItem)
        let slots = try (0..<3).map {
            try attachment(directory: directory, id: "slot-\($0)", position: $0)
        }
        let attached = try await store!.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            attachments: slots, compressionEnabled: true)
        var second = slots[1]
        second.preparedPath = second.sourcePath
        _ = try await store!.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: second)
        var third = slots[2]
        third.preparedPath = third.sourcePath
        third.attachmentID = "remote-2"
        let checkpoint = try await store!.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: third)
        XCTAssertEqual(checkpoint.draft.editRevision, attached.draft.editRevision)
        let blocked = try await store!.claimNext(chatID: "chat")
        XCTAssertNil(blocked.message)
        let released = try await store!.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "ignored", text: "", enqueuedAt: Date(),
            clearedDraftRevision: attached.draft.editRevision + 1)
        XCTAssertNil(released.composingItem)
        XCTAssertEqual(released.outgoing.first?.clientGeneratedID, item.clientGeneratedID)
        let unresolved = try await store!.claimNext(chatID: "chat")
        XCTAssertNil(unresolved.message)
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        let pending = try XCTUnwrap(restored.first?.outgoing.first)
        XCTAssertNil(restored.first?.composingItem)
        XCTAssertEqual(pending.attachments.map(\.attachmentID), [nil, nil, "remote-2"])
        var first = slots[0]
        first.preparedPath = first.sourcePath
        first.attachmentID = "remote-0"
        _ = try await store!.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: first)
        let stillUnresolved = try await store!.claimNext(chatID: "chat")
        XCTAssertNil(stillUnresolved.message)
        second.attachmentID = "remote-1"
        _ = try await store!.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: second)
        let claimed = try await store!.claimNext(chatID: "chat")
        XCTAssertEqual(claimed.message?.body.attachmentIds, ["remote-0", "remote-1", "remote-2"])
        XCTAssertEqual(claimed.message?.body.clientGeneratedId, item.clientGeneratedID)
        first.attachmentID = "replacement"
        let late = try await store!.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: first)
        XCTAssertEqual(late.outgoing.first?.body, claimed.message?.body)
    }

    func testReorderRetainsUploadsAndMergesInFlightCheckpointsIntoLatestOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let begun = try await store.beginComposition(chatID: "chat", senderID: 1)
        let item = try XCTUnwrap(begun.composingItem)
        let slots = try (0..<3).map {
            try attachment(directory: directory, id: "slot-\($0)", position: $0)
        }
        let attached = try await store.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            attachments: slots, compressionEnabled: true)
        var completed = slots[0]
        completed.preparedPath = completed.sourcePath
        completed.attachmentID = "remote-0"
        _ = try await store.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: completed)

        // Reordering from an editing snapshot that predates the PUT must retain its result.
        let reordered = try await store.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID,
            expectedRevision: attached.draft.editRevision,
            attachments: [slots[2], slots[0], slots[1]], compressionEnabled: true)
        XCTAssertEqual(reordered.draft.attachments.map(\.id), ["slot-2", "slot-0", "slot-1"])
        XCTAssertEqual(
            reordered.draft.attachments.map(\.generation),
            [slots[2].generation, slots[0].generation, slots[1].generation])
        XCTAssertEqual(reordered.draft.attachments[1].attachmentID, "remote-0")
        XCTAssertEqual(reordered.draft.attachments[1].preparedPath, completed.preparedPath)

        // Preparation began at position 1; its completion belongs at the new position 2.
        var prepared = slots[1]
        prepared.preparedPath = prepared.sourcePath
        let preparation = try await store.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: prepared)
        XCTAssertEqual(preparation.draft.attachments.map(\.position), [0, 1, 2])
        XCTAssertEqual(preparation.draft.attachments[2].preparedPath, prepared.preparedPath)
        XCTAssertEqual(preparation.draft.editRevision, reordered.draft.editRevision)
        var uploading = preparation.draft.attachments[2]

        // Remove another slot and reorder again while the prepared attachment's PUT is in flight.
        let removed = try await store.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID,
            expectedRevision: preparation.draft.editRevision,
            attachments: [preparation.draft.attachments[2], preparation.draft.attachments[1]],
            compressionEnabled: true)
        var removedCompletion = slots[2]
        removedCompletion.attachmentID = "orphan"
        let lateRemoved = try await store.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: removedCompletion)
        XCTAssertEqual(lateRemoved, removed)
        uploading.attachmentID = "remote-1"
        let uploaded = try await store.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: uploading)
        XCTAssertEqual(uploaded.draft.attachments.map(\.id), ["slot-1", "slot-0"])
        XCTAssertEqual(uploaded.draft.attachments.map(\.position), [0, 1])
        XCTAssertEqual(uploaded.draft.attachments.map(\.attachmentID), ["remote-1", "remote-0"])
        XCTAssertEqual(uploaded.draft.editRevision, removed.draft.editRevision)

        // An old-position duplicate is a no-op, and late preparation cannot undo a successful PUT.
        let duplicate = try await store.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: completed)
        XCTAssertEqual(duplicate, uploaded)
        let latePreparation = try await store.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: prepared)
        XCTAssertEqual(latePreparation, uploaded)
        _ = try await store.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "ignored", text: "", enqueuedAt: Date(),
            clearedDraftRevision: uploaded.draft.editRevision + 1)
        let claim = try await store.claimNext(chatID: "chat")
        XCTAssertEqual(claim.message?.body.attachmentIds, ["remote-1", "remote-0"])
    }

    func testSourceAndCompressionChangesRejectStaleAttachmentWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let begun = try await store.beginComposition(chatID: "chat", senderID: 1)
        let item = try XCTUnwrap(begun.composingItem)
        let slots = try (0..<2).map {
            try attachment(directory: directory, id: "slot-\($0)", position: $0)
        }
        var snapshot = try await store.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            attachments: slots, compressionEnabled: true)
        for var slot in slots {
            slot.preparedPath = slot.sourcePath
            slot.attachmentID = "remote-\(slot.id)"
            snapshot = try await store.checkpointAttachment(
                chatID: "chat", itemID: item.clientGeneratedID, attachment: slot)
        }
        var replacement = try attachment(directory: directory, id: "replacement", position: 0)
        replacement.id = slots[0].id
        replacement.generation = slots[0].generation
        let changedSource = try await store.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID,
            expectedRevision: snapshot.draft.editRevision,
            attachments: [replacement, snapshot.draft.attachments[1]], compressionEnabled: true)
        XCTAssertNil(changedSource.draft.attachments[0].preparedPath)
        XCTAssertNil(changedSource.draft.attachments[0].attachmentID)
        XCTAssertNotEqual(changedSource.draft.attachments[0].generation, slots[0].generation)
        XCTAssertEqual(changedSource.draft.attachments[1], snapshot.draft.attachments[1])
        let lateSource = try await store.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID,
            attachment: snapshot.draft.attachments[0])
        XCTAssertEqual(lateSource, changedSource)

        // Even a matching generation cannot checkpoint different source/preview ownership.
        var wrongSource = snapshot.draft.attachments[0]
        wrongSource.generation = changedSource.draft.attachments[0].generation
        let rejectedSource = try await store.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: wrongSource)
        XCTAssertEqual(rejectedSource, changedSource)
        var wrongPreview = changedSource.draft.attachments[0]
        wrongPreview.previewPath = slots[1].previewPath
        wrongPreview.attachmentID = "wrong-preview"
        let rejectedPreview = try await store.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: wrongPreview)
        XCTAssertEqual(rejectedPreview, changedSource)

        var completedReplacement = changedSource.draft.attachments[0]
        completedReplacement.preparedPath = completedReplacement.sourcePath
        completedReplacement.attachmentID = "replacement-upload"
        let completed = try await store.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: completedReplacement)
        let changedOptions = try await store.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID,
            expectedRevision: completed.draft.editRevision,
            attachments: completed.draft.attachments, compressionEnabled: false)
        for index in changedOptions.draft.attachments.indices {
            XCTAssertNil(changedOptions.draft.attachments[index].preparedPath)
            XCTAssertNil(changedOptions.draft.attachments[index].attachmentID)
            XCTAssertNotEqual(
                changedOptions.draft.attachments[index].generation,
                completed.draft.attachments[index].generation)
            let lateOptions = try await store.checkpointAttachment(
                chatID: "chat", itemID: item.clientGeneratedID,
                attachment: completed.draft.attachments[index])
            XCTAssertEqual(lateOptions, changedOptions)
        }
        do {
            _ = try await store.setCompositionAttachments(
                chatID: "chat", itemID: item.clientGeneratedID,
                expectedRevision: changedOptions.draft.editRevision,
                attachments: completed.draft.attachments, compressionEnabled: false)
            XCTFail("An old content generation must not overwrite the edited composition")
        } catch LocalStorageError.staleDraft {}
        let staleText = try await store.saveDraft(
            chatID: "chat", text: "late text", editRevision: changedSource.draft.editRevision,
            updatedAt: Date())
        XCTAssertEqual(staleText.draft.text, "")
        XCTAssertEqual(staleText.draft.attachments, changedOptions.draft.attachments)
        do {
            _ = try await store.enqueueText(
                chatID: "chat", senderID: 1, clientGeneratedID: "stale", text: "",
                enqueuedAt: Date(), clearedDraftRevision: completed.draft.editRevision)
            XCTFail("An old composer must not release a newly edited composition")
        } catch LocalStorageError.staleDraft {}
    }

    func testDiscardedDraftAttachmentsRejectLatePreparationAndUploadAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let begun = try await store!.beginComposition(chatID: "chat", senderID: 1)
        let item = try XCTUnwrap(begun.composingItem)
        var preparing = try attachment(directory: directory, id: "preparing", position: 0)
        var uploading = try attachment(directory: directory, id: "uploading", position: 1)
        uploading.preparedPath = uploading.sourcePath
        let attached = try await store!.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            attachments: [preparing, uploading], compressionEnabled: true)
        let reply = preview(id: "target")
        let saved = try await store!.saveDraft(
            chatID: "chat", text: "keep this caption",
            editRevision: attached.draft.editRevision + 1,
            updatedAt: Date(), replyToMessage: reply)
        let discarded = try await store!.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID,
            expectedRevision: saved.draft.editRevision,
            attachments: [], compressionEnabled: true)
        XCTAssertTrue(discarded.draft.attachments.isEmpty)
        XCTAssertEqual(discarded.draft.text, saved.draft.text)
        XCTAssertEqual(discarded.draft.replyToMessage, reply)

        // The blocked composition still exists; its retired slot IDs must not be recreated.
        preparing.preparedPath = preparing.sourcePath
        let latePreparation = try await store!.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: preparing)
        XCTAssertEqual(latePreparation, discarded)
        uploading.attachmentID = "late-upload"
        let lateUpload = try await store!.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: uploading)
        XCTAssertEqual(lateUpload, discarded)

        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        XCTAssertEqual(restored.first, discarded)
        _ = try await store!.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "unused", text: discarded.draft.text,
            enqueuedAt: Date(), clearedDraftRevision: discarded.draft.editRevision + 1,
            replyToMessage: discarded.draft.replyToMessage)
        let claim = try await store!.claimNext(chatID: "chat")
        XCTAssertEqual(claim.message?.body.clientGeneratedId, item.clientGeneratedID)
        XCTAssertEqual(claim.message?.body.message, "keep this caption")
        XCTAssertEqual(claim.message?.body.replyToId, reply.id)
        XCTAssertEqual(claim.message?.body.attachmentIds, [])
    }

    func testRevocationIgnoresLateUploadAndCannotResurrectComposition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let begun = try await store.beginComposition(chatID: "chat", senderID: 1)
        let item = try XCTUnwrap(begun.composingItem)
        var slot = try attachment(directory: directory, id: "slot", position: 0)
        let attached = try await store.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            attachments: [slot], compressionEnabled: true)
        let released = try await store.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "ignored", text: "", enqueuedAt: Date(),
            clearedDraftRevision: attached.draft.editRevision + 1)
        let pending = try XCTUnwrap(released.outgoing.first)
        _ = try await store.revokeTail(
            chatID: "chat", itemID: pending.clientGeneratedID,
            expectedRevision: pending.editRevision)
        slot.attachmentID = "orphan"
        let late = try await store.checkpointAttachment(
            chatID: "chat", itemID: pending.clientGeneratedID, attachment: slot)
        XCTAssertTrue(late.outgoing.isEmpty)
        XCTAssertNil(late.composingItem)
        let stale = try await store.saveDraft(
            chatID: "chat", text: "stale", editRevision: attached.draft.editRevision,
            updatedAt: Date())
        XCTAssertNil(stale.composingItem)
        let claim = try await store.claimNext(chatID: "chat")
        XCTAssertNil(claim.message)
    }

    func testClaimBoundaryStaysFrozenThroughFailureAndRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let queued = try await store!.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "sealed", enqueuedAt: Date(),
            clearedDraftRevision: 1)
        let pending = try XCTUnwrap(queued.outgoing.first)
        let blocked = try await store!.blockTail(
            chatID: "chat", itemID: "A", expectedRevision: pending.editRevision)
        XCTAssertEqual(blocked.draft.itemID, "A")
        XCTAssertTrue(blocked.outgoing.isEmpty)
        let noClaim = try await store!.claimNext(chatID: "chat")
        XCTAssertNil(noClaim.message)
        _ = try await store!.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "unused", text: "sealed",
            enqueuedAt: Date(), clearedDraftRevision: blocked.draft.editRevision + 1)
        let claimed = try await store!.claimNext(chatID: "chat")
        let revision = try XCTUnwrap(claimed.message?.editRevision)
        do {
            _ = try await store!.revokeTail(chatID: "chat", itemID: "A", expectedRevision: revision)
            XCTFail("A claimed request has no guaranteed local revocation")
        } catch LocalStorageError.dispatchAlreadyClaimed {}
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        _ = try await store!.restore()
        _ = try await store!.fail(chatID: "chat", clientGeneratedID: "A")
        _ = try await store!.retry(chatID: "chat", clientGeneratedID: "A", scope: .message)
        do {
            _ = try await store!.blockTail(chatID: "chat", itemID: "A", expectedRevision: revision)
            XCTFail("Recovery or retry must not unfreeze an uncertain request")
        } catch LocalStorageError.dispatchAlreadyClaimed {}
        let retry = try await store!.claimNext(chatID: "chat")
        XCTAssertEqual(retry.message?.body, claimed.message?.body)
    }

    func testConcurrentReleaseCreatesOneItemAndTailCannotBeBypassed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let draft = try await store.saveDraft(
            chatID: "chat", text: "once", editRevision: 1, updatedAt: Date())
        let first = Task {
            try await store.enqueueText(
                chatID: "chat", senderID: 1, clientGeneratedID: "first", text: "once",
                enqueuedAt: Date(), clearedDraftRevision: 2)
        }
        let second = Task {
            try await store.enqueueText(
                chatID: "chat", senderID: 1, clientGeneratedID: "second", text: "once",
                enqueuedAt: Date(), clearedDraftRevision: 2)
        }
        var successes = 0
        for task in [first, second] {
            do {
                _ = try await task.value
                successes += 1
            } catch LocalStorageError.staleDraft {}
        }
        XCTAssertEqual(successes, 1)
        let snapshots = try await store.restore()
        XCTAssertEqual(
            snapshots.first?.outgoing.map(\.clientGeneratedID), [try XCTUnwrap(draft.draft.itemID)])
        let pending = try XCTUnwrap(snapshots.first?.outgoing.first)
        let next = try await store.beginComposition(chatID: "chat", senderID: 1)
        do {
            _ = try await store.blockTail(
                chatID: "chat", itemID: pending.clientGeneratedID,
                expectedRevision: pending.editRevision)
            XCTFail("Blocking an older row must not move it behind the composing tail")
        } catch LocalStorageError.notTail {}
        let claim = try await store.claimNext(chatID: "chat")
        XCTAssertEqual(claim.message?.clientGeneratedID, pending.clientGeneratedID)
        XCTAssertEqual(
            claim.snapshot.composingItem?.clientGeneratedID, next.composingItem?.clientGeneratedID)
    }

    func testConcurrentClaimAndRevokeHaveOneDurableWinner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let queued = try await store.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "race", enqueuedAt: Date(),
            clearedDraftRevision: 1)
        let pending = try XCTUnwrap(queued.outgoing.first)
        let claimTask = Task { try await store.claimNext(chatID: "chat") }
        let revokeTask = Task {
            try await store.revokeTail(
                chatID: "chat", itemID: "A", expectedRevision: pending.editRevision)
        }
        let claim = try await claimTask.value
        if let claimed = claim.message {
            do {
                _ = try await revokeTask.value
                XCTFail("Claim and revocation cannot both win")
            } catch LocalStorageError.dispatchAlreadyClaimed {}
            XCTAssertEqual(claimed.body.clientGeneratedId, "A")
            let restored = try await store.restore()
            XCTAssertEqual(restored.first?.outgoing.first?.body, claimed.body)
        } else {
            let revoked = try await revokeTask.value
            XCTAssertTrue(revoked.outgoing.isEmpty)
            let restored = try await store.restore()
            XCTAssertTrue(try XCTUnwrap(restored.first).outgoing.isEmpty)
        }
    }

    func testAccountRelocationResolvesDurableAttachmentPathsAtNewDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let relocated = root.appendingPathComponent("relocated")
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: original)
        let begun = try await store!.beginComposition(chatID: "chat", senderID: 1)
        let item = try XCTUnwrap(begun.composingItem)
        let source = try attachment(directory: original, id: "slot", position: 0)
        let attached = try await store!.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            attachments: [source], compressionEnabled: true)
        var prepared = source
        prepared.preparedPath = source.sourcePath
        _ = try await store!.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: prepared)
        store = nil
        try FileManager.default.moveItem(at: original, to: relocated)
        let reopened = try ChahuaLocalStore(directory: relocated)
        let snapshots = try await reopened.restore()
        var restored = try XCTUnwrap(snapshots.first?.draft.attachments.first)
        XCTAssertEqual(restored.sourcePath, relocated.appendingPathComponent("slot.png").path)
        XCTAssertEqual(restored.previewPath, restored.sourcePath)
        XCTAssertEqual(restored.preparedPath, restored.sourcePath)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: restored.sourcePath)), Data([1, 2, 3]))
        restored.attachmentID = "allocated"
        _ = try await reopened.checkpointAttachment(
            chatID: "chat", itemID: item.clientGeneratedID, attachment: restored)
        _ = try await reopened.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "unused", text: "", enqueuedAt: Date(),
            clearedDraftRevision: attached.draft.editRevision + 1)
        let claim = try await reopened.claimNext(chatID: "chat")
        XCTAssertEqual(claim.message?.body.attachmentIds, ["allocated"])
    }

    func testCompositionRejectsFilesOutsideAccountAndNonregularSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("account")
        let store = try ChahuaLocalStore(directory: directory)
        let begun = try await store.beginComposition(chatID: "chat", senderID: 1)
        let item = try XCTUnwrap(begun.composingItem)
        let outside = try attachment(directory: root, id: "outside", position: 0)
        do {
            _ = try await store.setCompositionAttachments(
                chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
                attachments: [outside], compressionEnabled: true)
            XCTFail("Another account's file cannot become this item's durable source")
        } catch LocalStorageError.invalidAttachments {}
        var nonregular = try attachment(directory: directory, id: "inside", position: 0)
        let folder = directory.appendingPathComponent("not-a-file")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        nonregular.sourcePath = folder.path
        do {
            _ = try await store.setCompositionAttachments(
                chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
                attachments: [nonregular], compressionEnabled: true)
            XCTFail("A directory cannot satisfy durable source ownership")
        } catch LocalStorageError.invalidAttachments {}
        let restored = try await store.restore()
        XCTAssertEqual(restored.first?.composingItem, item)
    }

    private func attachment(directory: URL, id: String, position: Int) throws
        -> LocalOutgoingAttachment
    {
        let file = directory.appendingPathComponent("\(id).png")
        try Data([1, 2, 3]).write(to: file, options: .atomic)
        return LocalOutgoingAttachment(
            id: id, generation: UUID().uuidString, position: position, sourcePath: file.path,
            previewPath: file.path, fileName: file.lastPathComponent, mimeType: "image/png",
            width: 10, height: 10, byteCount: 3)
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
