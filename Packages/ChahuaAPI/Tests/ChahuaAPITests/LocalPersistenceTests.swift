import Foundation
import GRDB
import XCTest

@testable import ChahuaAPI

final class LocalPersistenceTests: XCTestCase {
    func testMigrationDiscardsLegacyWorkOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createLegacyStore(directory)

        do {
            let store = try ChahuaLocalStore(directory: directory, userID: 17)
            let restored = try await store.restore()
            XCTAssertTrue(restored.isEmpty)
            _ = try await store.enqueueIndependentText(
                chatID: "chat", threadID: "thread", clientGeneratedID: "new-work",
                text: "new send", enqueuedAt: Date())
        }

        let reopened = try ChahuaLocalStore(directory: directory, userID: 17)
        let restored = try await reopened.restore()
        XCTAssertEqual(restored.flatMap(\.outgoing).map(\.clientGeneratedID), ["new-work"])
        XCTAssertEqual(restored.first?.outgoing.first?.senderID, 17)
    }

    func testInterruptedSendingCanOnlyRetryTheSameCreate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ConversationKey(chatID: "chat", threadID: "thread")
        let before: LocalOutgoingMessage
        do {
            let store = try ChahuaLocalStore(directory: directory, userID: 17)
            var slot = try image(directory, id: "photo")
            slot.attachmentID = "uploaded"
            _ = try await store.setDraftAttachments(key: key, attachments: [slot], compressionEnabled: false)
            _ = try await store.enqueueText(
                chatID: key.chatID, threadID: key.threadID, clientGeneratedID: "attempt",
                text: "original", enqueuedAt: Date(), clearedDraftRevision: 1,
                replyToMessage: receipt("reply", key: key).replyPreview,
                metadata: MessageMetadataInput(linkPreviews: [.init(url: "https://example.com")]))
            let claimed = try await store.claimNext(chatID: key.chatID, threadID: key.threadID, expectedID: "attempt")
            before = try XCTUnwrap(claimed.message)
            XCTAssertEqual(before.state, .sending)
            do {
                _ = try await store.removeOutgoing(key: key, itemID: "attempt")
                XCTFail("An active create cannot be removed")
            } catch LocalStorageError.outgoingSending {}
        }

        let reopened = try ChahuaLocalStore(directory: directory, userID: 17)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded.first?.outgoing.first, before)
        let restored = try await reopened.restore()
        let failed = try XCTUnwrap(restored.first?.outgoing.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failure, .init(stage: .create, reason: .unknownOutcome, retry: .automatic))
        XCTAssertFalse(failed.isEditable)
        do {
            _ = try await reopened.editOutgoing(
                key: key, itemID: "attempt", text: "changed", replyToMessage: nil, attachments: [],
                compressionEnabled: true)
            XCTFail("Recovery must not open an editable interval")
        } catch LocalStorageError.outgoingNotEditable {}
        let blocked = try await reopened.claimNext(chatID: key.chatID, threadID: key.threadID, expectedID: "attempt")
        XCTAssertNil(blocked.message)
        let retry = try await reopened.claimNext(
            chatID: key.chatID, threadID: key.threadID, expectedID: "attempt", retryCreate: true)
        XCTAssertEqual(retry.message, before)
        XCTAssertEqual(retry.message?.body, before.body)
    }

    func testFIFOBoundaryAndAuthoritativeSettlement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let thread = ConversationKey(chatID: "chat", threadID: "thread")
        let parent = ConversationKey(chatID: "chat")
        let slot = try image(directory, id: "photo")
        _ = try await store.setDraftAttachments(key: thread, attachments: [slot], compressionEnabled: true)
        _ = try await store.enqueueText(
            chatID: "chat", threadID: "thread", clientGeneratedID: "A", text: "",
            enqueuedAt: Date(), clearedDraftRevision: 1)
        _ = try await store.enqueueIndependentText(
            chatID: "chat", threadID: "thread", clientGeneratedID: "B", text: "second",
            enqueuedAt: Date())
        _ = try await store.enqueueIndependentText(
            chatID: "chat", clientGeneratedID: "C", text: "independent", enqueuedAt: Date())

        let preparing = try await store.claimNext(chatID: "chat", threadID: "thread", expectedID: "A")
        XCTAssertNil(preparing.message)
        XCTAssertEqual(preparing.snapshot.outgoing.map(\.clientGeneratedID), ["A", "B"])
        let blocked = try await store.claimNext(chatID: "chat", threadID: "thread", expectedID: "B")
        XCTAssertNil(blocked.message)
        let independent = try await store.claimNext(chatID: "chat", expectedID: "C")
        XCTAssertEqual(independent.message?.clientGeneratedID, "C")

        var uploaded = slot
        uploaded.attachmentID = "upload"
        _ = try await store.checkpointAttachment(key: thread, itemID: "A", attachment: uploaded)
        let claim = try await store.claimNext(chatID: "chat", threadID: "thread", expectedID: "A")
        XCTAssertEqual(claim.message?.body.attachmentIds, ["upload"])
        let failure = OutboxFailure(stage: .create, reason: .rejected, retry: .manual)
        _ = try await store.fail(key: thread, itemID: "A", failure: failure)
        let behindFailed = try await store.claimNext(chatID: "chat", threadID: "thread", expectedID: "B")
        XCTAssertNil(behindFailed.message)
        XCTAssertEqual(behindFailed.snapshot.outgoing.first?.failure, failure)

        for wrong in [
            receipt("wrong-id", key: thread),
            receipt("A", key: thread, senderID: 1),
            receipt("A", key: parent),
            receipt("A", key: ConversationKey(chatID: "other", threadID: "thread")),
            receipt("B", key: thread),
        ] {
            let mismatch = try await store.settleCreate(wrong)
            XCTAssertNil(mismatch)
        }
        let deletedServerCopy = receipt("A", key: thread, deleted: true)
        let settled = try await store.settleCreate(deletedServerCopy)
        XCTAssertEqual(settled?.outgoing.map(\.clientGeneratedID), ["B"])
        let duplicate = try await store.settleCreate(deletedServerCopy)
        XCTAssertNil(duplicate)
        let lateFailure = try await store.fail(key: thread, itemID: "A", failure: failure)
        XCTAssertEqual(lateFailure, settled)
        let next = try await store.claimNext(chatID: "chat", threadID: "thread", expectedID: "B")
        XCTAssertEqual(next.message?.clientGeneratedID, "B")
    }

    func testDraftSubmitRollsBackRowsAndWatermarkOnStorageFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let date = Date()
        let draft = try await store.saveDraft(
            chatID: "chat", text: "draft", editRevision: 1, updatedAt: date)
        let database = try DatabaseQueue(path: directory.appendingPathComponent("chat.sqlite").path)
        try await database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER reject_clear BEFORE DELETE ON draft
                    BEGIN SELECT RAISE(ABORT, 'reject clear'); END;
                    """)
        }
        do {
            _ = try await store.enqueueText(
                chatID: "chat", clientGeneratedID: "attempt", text: "draft", enqueuedAt: date,
                clearedDraftRevision: 2)
            XCTFail("Enqueue must roll back if clearing the draft fails")
        } catch is DatabaseError {}
        let afterRollback = try await store.load()
        XCTAssertEqual(afterRollback, [draft])
        try await database.write { db in try db.execute(sql: "DROP TRIGGER reject_clear") }
        let sent = try await store.enqueueText(
            chatID: "chat", clientGeneratedID: "attempt", text: "draft", enqueuedAt: date,
            clearedDraftRevision: 2)
        XCTAssertEqual(sent.revision, draft.revision + 1)
        XCTAssertEqual(sent.draft.editRevision, 2)
        XCTAssertEqual(sent.draft.text, "")
        XCTAssertEqual(sent.outgoing.map(\.clientGeneratedID), ["attempt"])
        let stale = try await store.saveDraft(
            chatID: "chat", text: "do not resurrect", editRevision: 2, updatedAt: date)
        XCTAssertEqual(stale, sent)
    }

    func testCheckpointsFollowMovedAndReorderedSlotsButNotReplacedGeneration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let key = ConversationKey(chatID: "chat")
        let a = try image(directory, id: "a")
        let b = try image(directory, id: "b")
        let attached = try await store.setDraftAttachments(key: key, attachments: [a, b], compressionEnabled: true)
        let original = attached.draft.attachments
        var uploadedA = a
        uploadedA.attachmentID = "uploaded-a"
        _ = try await store.checkpointAttachment(key: key, itemID: nil, attachment: uploadedA)
        let sent = try await store.enqueueText(
            chatID: "chat", clientGeneratedID: "item", text: "original", enqueuedAt: Date(),
            clearedDraftRevision: 1)
        XCTAssertEqual(sent.outgoing.first?.attachments.first, uploadedA)
        var uploadedB = b
        uploadedB.attachmentID = "uploaded-b"
        _ = try await store.checkpointAttachment(key: key, itemID: nil, attachment: uploadedB)

        let edited = try await store.editOutgoing(
            key: key, itemID: "item", text: "edited", replyToMessage: nil,
            attachments: [original[1], original[0]], compressionEnabled: true)
        let row = try XCTUnwrap(edited.outgoing.first)
        XCTAssertEqual(row.attachments.map(\.id), ["b", "a"])
        XCTAssertEqual(row.attachments.map(\.position), [0, 1])
        XCTAssertEqual(row.body.attachmentIds, ["uploaded-b", "uploaded-a"])

        let changed = try await store.editOutgoing(
            key: key, itemID: "item", text: "edited", replyToMessage: nil,
            attachments: row.attachments, compressionEnabled: false)
        XCTAssertEqual(changed.outgoing.first?.isReadyForDispatch, false)
        XCTAssertNotEqual(changed.outgoing.first?.attachments.first?.generation, b.generation)
        let stale = try await store.checkpointAttachment(key: key, itemID: "item", attachment: uploadedB)
        XCTAssertEqual(stale, changed)
    }

    func testFailedPreparationMovesWithDraftAndRetriesOnlyPreparation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let key = ConversationKey(chatID: "chat")
        let slot = try image(directory, id: "photo")
        _ = try await store.setDraftAttachments(key: key, attachments: [slot], compressionEnabled: true)
        let failure = OutboxFailure(stage: .preparation, reason: .tooLarge(8), retry: .manual)
        _ = try await store.checkpointAttachment(key: key, itemID: nil, attachment: slot, failure: failure)
        let submitted = try await store.enqueueText(
            chatID: "chat", clientGeneratedID: "item", text: "", enqueuedAt: Date(),
            clearedDraftRevision: 1)
        XCTAssertEqual(submitted.outgoing.first?.failure, failure)
        XCTAssertEqual(submitted.outgoing.first?.isEditable, true)
        let restore = try await store.restore()
        XCTAssertEqual(restore.first?.outgoing.first?.attachments.first?.failure, .tooLarge(8))
        let retryCreate = try await store.claimNext(chatID: "chat", expectedID: "item", retryCreate: true)
        XCTAssertNil(retryCreate.message)
        let retry = try await store.retryPreparation(key: key, itemID: "item")
        XCTAssertEqual(retry.outgoing.first?.state, .pending)
        XCTAssertNil(retry.outgoing.first?.attachments.first?.failure)
        let stillPreparing = try await store.claimNext(chatID: "chat", expectedID: "item")
        XCTAssertNil(stillPreparing.message)
        _ = try await store.checkpointAttachment(key: key, itemID: "item", attachment: slot, failure: failure)
        let fixed = try await store.editOutgoing(
            key: key, itemID: "item", text: "without the oversize photo", replyToMessage: nil,
            attachments: [], compressionEnabled: true)
        XCTAssertEqual(fixed.outgoing.first?.state, .pending)
        XCTAssertNil(fixed.outgoing.first?.failure)
        XCTAssertEqual(fixed.outgoing.first?.isReadyForDispatch, true)
    }

    func testFileCaptionFollowsFileAndIndependentSendDoesNotConsumeDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let key = ConversationKey(chatID: "chat")
        let caption = "https://example.com"
        let reply = receipt("reply", key: key).replyPreview
        let metadata = MessageMetadataInput(linkPreviews: [.init(url: caption, status: .disabled)])
        _ = try await store.saveDraft(
            chatID: "chat", text: caption, editRevision: 1, updatedAt: Date(), replyToMessage: reply,
            linkPreviews: metadata.linkPreviews)
        var file = try image(directory, id: "file")
        file.preservesOriginal = true
        file.width = 0
        file.height = 0
        file.preparedPath = file.sourcePath
        file.attachmentID = "uploaded-file"
        let attached = try await store.setDraftAttachments(key: key, attachments: [file], compressionEnabled: false)
        let independent = try await store.enqueueIndependentText(
            chatID: "chat", clientGeneratedID: "notification", text: "reply", enqueuedAt: Date())
        XCTAssertEqual(independent.draft, attached.draft)
        let submitted = try await store.enqueueText(
            chatID: "chat", clientGeneratedID: "file-send", text: caption, enqueuedAt: Date(),
            clearedDraftRevision: 2, replyToMessage: reply, metadata: metadata)
        XCTAssertEqual(submitted.outgoing.map(\.position), [0, 1, 2])
        XCTAssertEqual(submitted.outgoing.map(\.messageType), [.text, .file, .text])
        XCTAssertEqual(submitted.outgoing[1].clientGeneratedID, "file-send")
        XCTAssertEqual(submitted.outgoing[1].body.attachmentIds, ["uploaded-file"])
        XCTAssertEqual(submitted.outgoing[1].body.replyToId, reply.id)
        XCTAssertNil(submitted.outgoing[1].body.message)
        XCTAssertNil(submitted.outgoing[1].body.metadata)
        XCTAssertEqual(submitted.outgoing[2].body.message, caption)
        XCTAssertEqual(submitted.outgoing[2].body.metadata, metadata)
        XCTAssertNil(submitted.outgoing[2].body.replyToId)
    }

    func testEmptyDraftAndPurgeOnlyAffectThisAccountsRows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let other = try ChahuaLocalStore(
            directory: directory.appendingPathComponent("other-account"), userID: 21)
        let date = Date()
        _ = try await store.saveDraft(chatID: "chat", text: "a draft", editRevision: 1, updatedAt: date)
        _ = try await store.saveDraft(chatID: "chat", text: "", editRevision: 2, updatedAt: date)
        let hasEmptyDraft = try await store.hasWork()
        XCTAssertFalse(hasEmptyDraft)
        _ = try await store.saveDraft(chatID: "chat", text: "new draft", editRevision: 3, updatedAt: date)
        _ = try await store.enqueueIndependentText(
            chatID: "chat", clientGeneratedID: "ours", text: "our send", enqueuedAt: date)
        _ = try await other.enqueueIndependentText(
            chatID: "chat", clientGeneratedID: "theirs", text: "their send", enqueuedAt: date)
        try await store.purge()
        let ourWork = try await store.hasWork()
        let theirWork = try await other.hasWork()
        XCTAssertFalse(ourWork)
        XCTAssertTrue(theirWork)
    }

    private func createLegacyStore(_ directory: URL) throws {
        let database = try DatabaseQueue(path: directory.appendingPathComponent("chat.sqlite").path)
        try database.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                    INSERT INTO grdb_migrations VALUES
                        ('v1_drafts_outbox'), ('v2_reply_context'), ('v2_thread_conversations'),
                        ('v3_reply_context'), ('v4_blocked_image_outbox'), ('v5_sticker_outbox'),
                        ('v6_forwarding_outbox'), ('v7_speaking_restriction'), ('v8_outgoing_intents'),
                        ('v9_link_preview_intents');
                    CREATE TABLE local_conversation (
                        chat_id TEXT NOT NULL, thread_id TEXT NOT NULL, revision INTEGER NOT NULL,
                        next_enqueue_sequence INTEGER NOT NULL, PRIMARY KEY(chat_id, thread_id)
                    );
                    CREATE TABLE draft_revision (
                        chat_id TEXT NOT NULL, thread_id TEXT NOT NULL, edit_revision INTEGER NOT NULL,
                        updated_at REAL NOT NULL, PRIMARY KEY(chat_id, thread_id),
                        FOREIGN KEY(chat_id, thread_id) REFERENCES local_conversation(chat_id, thread_id)
                    );
                    CREATE TABLE outgoing_message (
                        client_generated_id TEXT PRIMARY KEY NOT NULL,
                        chat_id TEXT NOT NULL, thread_id TEXT NOT NULL, sender_id INTEGER NOT NULL,
                        text TEXT NOT NULL, enqueue_sequence INTEGER NOT NULL,
                        state TEXT NOT NULL, is_blocked INTEGER NOT NULL,
                        attachments BLOB NOT NULL, claimed_patch BLOB,
                        FOREIGN KEY(chat_id, thread_id) REFERENCES local_conversation(chat_id, thread_id)
                    );
                    INSERT INTO local_conversation VALUES ('chat', 'thread', 4, 2);
                    INSERT INTO draft_revision VALUES ('chat', 'thread', 3, 1);
                    INSERT INTO outgoing_message VALUES
                        ('old-send', 'chat', 'thread', 17, 'pending edit', 0, 'sending', 0, X'5B5D', X'7B7D'),
                        ('old-draft', 'chat', 'thread', 17, 'draft', 1, 'queued', 1, X'5B5D', NULL);
                    """)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func receipt(
        _ id: String, key: ConversationKey, senderID: Int32 = 17, deleted: Bool = false
    ) -> MessageResponse {
        MessageResponse(
            id: MessageID(7), chatId: key.chatID, clientGeneratedId: id, messageType: .text,
            sender: User(uid: senderID, gender: 0, name: nil, avatarUrl: nil, userGroup: nil),
            createdAt: Date(timeIntervalSince1970: 1), isDeleted: deleted,
            message: deleted ? nil : "different server text", replyRootId: key.threadID)
    }

    private func image(_ directory: URL, id: String) throws -> LocalOutgoingAttachment {
        let file = directory.appendingPathComponent("\(id).png")
        try Data([1, 2, 3]).write(to: file)
        return LocalOutgoingAttachment(
            id: id, generation: UUID().uuidString, position: 0, sourcePath: file.path,
            previewPath: file.path, fileName: file.lastPathComponent, mimeType: "image/png",
            width: 10, height: 10, byteCount: 3)
    }
}
