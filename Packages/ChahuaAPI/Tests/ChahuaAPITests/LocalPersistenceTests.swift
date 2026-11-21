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

    func testV10PreservesWorkAndUnknownMigrationResetsOnlyItsAccount() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = directory.appendingPathComponent("17")
        let other = try ChahuaLocalStore(
            directory: directory.appendingPathComponent("18"), userID: 18)
        let date = Date(timeIntervalSince1970: 1)
        _ = try await other.enqueueIndependentText(
            chatID: "chat", clientGeneratedID: "other", text: "other", enqueuedAt: date)
        do {
            let store = try ChahuaLocalStore(directory: account, userID: 17)
            _ = try await store.saveDraft(
                chatID: "chat", text: "draft", editRevision: 1, updatedAt: date)
            _ = try await store.enqueueIndependentText(
                chatID: "chat", clientGeneratedID: "pending", text: "pending", enqueuedAt: date)
        }
        try editMigrationDatabase(account) { db in
            try rewindMessageSyncMigration(db)
            for table in [
                "cached_member", "cached_message", "cached_segment", "cached_scope",
                "cached_conversation",
                "cached_list", "cached_tombstone", "pending_read", "cache_meta",
            ] {
                try db.drop(table: table)
            }
            try db.execute(
                sql: """
                    ALTER TABLE outgoing_message DROP COLUMN retry_not_before;
                    DELETE FROM grdb_migrations WHERE identifier IN ('v11_conversation_cache', 'v12_outbox_retry_deadline');
                    """)
        }
        do {
            let upgraded = try ChahuaLocalStore(directory: account, userID: 17)
            let saved = try await upgraded.restore()
            XCTAssertEqual(saved.first?.draft.text, "draft")
            XCTAssertEqual(saved.flatMap(\.outgoing).map(\.clientGeneratedID), ["pending"])
        }
        try editMigrationDatabase(account) { db in
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v99_future')")
        }
        do {
            let reset = try ChahuaLocalStore(directory: account, userID: 17)
            let restored = try await reset.restore()
            XCTAssertTrue(restored.isEmpty)
            _ = try await reset.enqueueIndependentText(
                chatID: "chat", clientGeneratedID: "after-reset", text: "new", enqueuedAt: date)
        }
        let reopened = try await ChahuaLocalStore(directory: account, userID: 17).restore()
        let otherRows = try await other.restore()
        XCTAssertEqual(reopened.flatMap(\.outgoing).map(\.clientGeneratedID), ["after-reset"])
        XCTAssertEqual(otherRows.flatMap(\.outgoing).map(\.clientGeneratedID), ["other"])
    }

    func testV12MigrationPreservesDraftAndOutbox() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ConversationKey(chatID: "chat")
        let date = Date(timeIntervalSince1970: 1)
        let before: [LocalConversationSnapshot]
        do {
            let store = try ChahuaLocalStore(directory: directory, userID: 17)
            _ = try await store.saveDraft(
                chatID: key.chatID, text: "draft", editRevision: 1, updatedAt: date)
            _ = try await store.enqueueIndependentText(
                chatID: key.chatID, clientGeneratedID: "pending", text: "send", enqueuedAt: date)
            before = try await store.load()
        }
        try editMigrationDatabase(directory, rewindMessageSyncMigration)

        let upgraded = try ChahuaLocalStore(directory: directory, userID: 17)
        let after = try await upgraded.load()
        // Opening a store resets process-local revisions, independent of migration.
        XCTAssertEqual(after.first?.draft.text, before.first?.draft.text)
        XCTAssertEqual(after.first?.draft.updatedAt, before.first?.draft.updatedAt)
        XCTAssertEqual(after.flatMap(\.outgoing), before.flatMap(\.outgoing))
        let epoch = try await upgraded.cacheEpoch()
        let reset = try await upgraded.resetSyncChat(
            chatID: key.chatID, cursor: "baseline", purge: false, epoch: epoch)
        XCTAssertTrue(reset)
        let manifest = try await upgraded.syncResumeManifest(epoch: epoch)
        XCTAssertEqual(manifest, [MessageSyncCheckpoint(chatID: key.chatID, cursor: "baseline")])
    }

    func testMigrationFailureAndMalformedLedgerDoNotEraseWork() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try ChahuaLocalStore(directory: directory, userID: 17)
            _ = try await store.enqueueIndependentText(
                chatID: "chat", clientGeneratedID: "keep", text: "keep", enqueuedAt: Date())
        }
        // v12 will fail because its column already exists. The failure must not
        // be handled as permission to erase any existing outbox data.
        try editMigrationDatabase(directory) { db in
            try rewindMessageSyncMigration(db)
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = 'v12_outbox_retry_deadline'")
        }
        XCTAssertThrowsError(try ChahuaLocalStore(directory: directory, userID: 17)) {
            XCTAssertTrue($0 is DatabaseError)
        }
        try editMigrationDatabase(directory) { db in
            try db.execute(
                sql: "INSERT INTO grdb_migrations VALUES ('v12_outbox_retry_deadline'), (X'3132')")
        }
        XCTAssertThrowsError(try ChahuaLocalStore(directory: directory, userID: 17)) {
            guard case LocalStorageError.corruptRecord = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        try editMigrationDatabase(directory) { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE typeof(identifier) = 'blob'")
        }
        let restored = try await ChahuaLocalStore(directory: directory, userID: 17).restore()
        XCTAssertEqual(restored.flatMap(\.outgoing).map(\.clientGeneratedID), ["keep"])
    }

    func testRetryAfterFencesRestoredPendingAndFailedCreateClaims() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let deadline = now.addingTimeInterval(120)
        let preflight = ConversationKey(chatID: "preflight")
        let create = ConversationKey(chatID: "create")
        let failure = OutboxFailure(stage: .create, reason: .network, retry: .automatic)
        do {
            let store = try ChahuaLocalStore(directory: directory, userID: 17)
            for key in [preflight, create] {
                _ = try await store.enqueueIndependentText(
                    chatID: key.chatID, clientGeneratedID: key.chatID, text: "same body",
                    enqueuedAt: now)
                let claim = try await store.claimNext(chatID: key.chatID, expectedID: key.chatID)
                XCTAssertNotNil(claim.message)
            }
            _ = try await store.releaseUnsentClaim(
                key: preflight, itemID: preflight.chatID, priorFailure: nil,
                retryNotBefore: deadline)
            _ = try await store.fail(
                key: create, itemID: create.chatID, failure: failure, retryNotBefore: deadline)
        }

        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let restored = try await store.restore()
        for key in [preflight, create] {
            let item = try XCTUnwrap(restored.first { $0.conversationKey == key }?.outgoing.first)
            XCTAssertEqual(item.text, "same body")
            XCTAssertEqual(item.state, key == preflight ? .pending : .failed)
            XCTAssertEqual(
                try XCTUnwrap(item.retryNotBefore).timeIntervalSince(deadline), 0, accuracy: 0.001)
            let blocked = try await store.claimNext(
                chatID: key.chatID, expectedID: key.chatID, retryCreate: true)
            XCTAssertNil(blocked.message)
            XCTAssertEqual(blocked.snapshot.outgoing.first, item)
        }
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
            _ = try await store.setDraftAttachments(
                key: key, attachments: [slot], compressionEnabled: false)
            _ = try await store.enqueueText(
                chatID: key.chatID, threadID: key.threadID, clientGeneratedID: "attempt",
                text: "original", enqueuedAt: Date(), clearedDraftRevision: 1,
                replyToMessage: receipt("reply", key: key).replyPreview,
                metadata: MessageMetadataInput(linkPreviews: [.init(url: "https://example.com")]))
            let claimed = try await store.claimNext(
                chatID: key.chatID, threadID: key.threadID, expectedID: "attempt")
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
        XCTAssertEqual(
            failed.failure, .init(stage: .create, reason: .unknownOutcome, retry: .automatic))
        XCTAssertFalse(failed.isEditable)
        do {
            _ = try await reopened.editOutgoing(
                key: key, itemID: "attempt", text: "changed", replyToMessage: nil, attachments: [],
                compressionEnabled: true)
            XCTFail("Recovery must not open an editable interval")
        } catch LocalStorageError.outgoingNotEditable {}
        let blocked = try await reopened.claimNext(
            chatID: key.chatID, threadID: key.threadID, expectedID: "attempt")
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
        _ = try await store.setDraftAttachments(
            key: thread, attachments: [slot], compressionEnabled: true)
        _ = try await store.enqueueText(
            chatID: "chat", threadID: "thread", clientGeneratedID: "A", text: "",
            enqueuedAt: Date(), clearedDraftRevision: 1)
        _ = try await store.enqueueIndependentText(
            chatID: "chat", threadID: "thread", clientGeneratedID: "B", text: "second",
            enqueuedAt: Date())
        _ = try await store.enqueueIndependentText(
            chatID: "chat", clientGeneratedID: "C", text: "independent", enqueuedAt: Date())

        let preparing = try await store.claimNext(
            chatID: "chat", threadID: "thread", expectedID: "A")
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
        let behindFailed = try await store.claimNext(
            chatID: "chat", threadID: "thread", expectedID: "B")
        XCTAssertNil(behindFailed.message)
        XCTAssertEqual(behindFailed.snapshot.outgoing.first?.failure, failure)

        for wrong in [
            receipt("wrong-id", key: thread),
            receipt("A", key: thread, senderID: 1),
            receipt("A", key: parent),
            receipt("A", key: ConversationKey(chatID: "other", threadID: "thread")),
            receipt("B", key: thread),
        ] {
            let mismatch = try await store.settleCreate(wrong, published: true)
            XCTAssertNil(mismatch)
        }
        let deletedServerCopy = receipt("A", key: thread, deleted: true)
        let settled = try await store.settleCreate(deletedServerCopy, published: true)
        XCTAssertEqual(settled?.outgoing.map(\.clientGeneratedID), ["B"])
        let duplicate = try await store.settleCreate(deletedServerCopy, published: true)
        XCTAssertNil(duplicate)
        let epoch = try await store.cacheEpoch()
        try await store.cacheChange(
            .create(receipt("A", key: thread), thread, adjoining: nil), epoch: epoch)
        let history = try await store.cachedHistory(thread)
        XCTAssertTrue(
            history.messages.isEmpty, "A late server copy must respect the settled deletion")
        let lateFailure = try await store.fail(key: thread, itemID: "A", failure: failure)
        XCTAssertEqual(lateFailure, settled)
        let next = try await store.claimNext(chatID: "chat", threadID: "thread", expectedID: "B")
        XCTAssertEqual(next.message?.clientGeneratedID, "B")
    }

    func testPublishedSettlementRollsBackCacheAndClaimTogether() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let key = ConversationKey(chatID: "chat", threadID: "thread")
        _ = try await store.enqueueIndependentText(
            chatID: key.chatID, threadID: key.threadID, clientGeneratedID: "A", text: "local",
            enqueuedAt: Date())
        let claim = try await store.claimNext(
            chatID: key.chatID, threadID: key.threadID, expectedID: "A")
        let message = receipt("A", key: key)
        try await store.database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_settlement BEFORE DELETE ON outgoing_message
                    BEGIN SELECT RAISE(ABORT, 'settlement blocked'); END
                    """)
        }
        do {
            _ = try await store.settleCreate(message, published: true)
            XCTFail("The queue deletion must fail")
        } catch is DatabaseError {}
        let blocked = try await store.load()
        XCTAssertEqual(blocked, [claim.snapshot])
        let rolledBack = try await store.cachedHistory(key)
        XCTAssertTrue(rolledBack.messages.isEmpty)
        let bytes = try await store.cachedMessageBytes()
        XCTAssertEqual(bytes, 0)

        try await store.database.write { db in try db.execute(sql: "DROP TRIGGER fail_settlement") }
        let settled = try await store.settleCreate(message, published: true)
        XCTAssertEqual(settled?.outgoing, [])
        let late = try await store.settleCreate(
            message.replacingMessageText("late"), published: false)
        XCTAssertNil(late)
        let reopened = try ChahuaLocalStore(directory: directory, userID: 17)
        let history = try await reopened.cachedHistory(key)
        XCTAssertEqual(history.messages, [message])
        let pending = try await reopened.restore()
        XCTAssertTrue(pending.isEmpty)
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
        let attached = try await store.setDraftAttachments(
            key: key, attachments: [a, b], compressionEnabled: true)
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
        let stale = try await store.checkpointAttachment(
            key: key, itemID: "item", attachment: uploadedB)
        XCTAssertEqual(stale, changed)
    }

    func testFailedPreparationMovesWithDraftAndRetriesOnlyPreparation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let key = ConversationKey(chatID: "chat")
        let slot = try image(directory, id: "photo")
        _ = try await store.setDraftAttachments(
            key: key, attachments: [slot], compressionEnabled: true)
        let failure = OutboxFailure(stage: .preparation, reason: .tooLarge(8), retry: .manual)
        _ = try await store.checkpointAttachment(
            key: key, itemID: nil, attachment: slot, failure: failure)
        let submitted = try await store.enqueueText(
            chatID: "chat", clientGeneratedID: "item", text: "", enqueuedAt: Date(),
            clearedDraftRevision: 1)
        XCTAssertEqual(submitted.outgoing.first?.failure, failure)
        XCTAssertEqual(submitted.outgoing.first?.isEditable, true)
        let restore = try await store.restore()
        XCTAssertEqual(restore.first?.outgoing.first?.attachments.first?.failure, .tooLarge(8))
        let retryCreate = try await store.claimNext(
            chatID: "chat", expectedID: "item", retryCreate: true)
        XCTAssertNil(retryCreate.message)
        let retry = try await store.retryPreparation(key: key, itemID: "item")
        XCTAssertEqual(retry.outgoing.first?.state, .pending)
        XCTAssertNil(retry.outgoing.first?.attachments.first?.failure)
        let stillPreparing = try await store.claimNext(chatID: "chat", expectedID: "item")
        XCTAssertNil(stillPreparing.message)
        _ = try await store.checkpointAttachment(
            key: key, itemID: "item", attachment: slot, failure: failure)
        let fixed = try await store.editOutgoing(
            key: key, itemID: "item", text: "without the oversize photo", replyToMessage: nil,
            attachments: [], compressionEnabled: true)
        XCTAssertEqual(fixed.outgoing.first?.state, .pending)
        XCTAssertNil(fixed.outgoing.first?.failure)
        XCTAssertEqual(fixed.outgoing.first?.isReadyForDispatch, true)
    }

    func testAttachmentRetryAfterSurvivesReopenAndClearsOnReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ConversationKey(chatID: "chat")
        let slot = try image(directory, id: "photo")
        let deadline = Date().addingTimeInterval(120)
        let failure = OutboxFailure(stage: .preparation, reason: .network, retry: .automatic)
        do {
            let store = try ChahuaLocalStore(directory: directory, userID: 17)
            _ = try await store.setDraftAttachments(
                key: key, attachments: [slot], compressionEnabled: true)
            _ = try await store.enqueueText(
                chatID: key.chatID, clientGeneratedID: "item", text: "caption", enqueuedAt: Date(),
                clearedDraftRevision: 1)
            var throttled = slot
            throttled.retryNotBefore = deadline
            _ = try await store.checkpointAttachment(
                key: key, itemID: "item", attachment: throttled, failure: failure)
        }

        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let restored = try await store.restore()
        let item = try XCTUnwrap(restored.first?.outgoing.first)
        XCTAssertEqual(item.failure, failure)
        XCTAssertEqual(item.attachments.first?.retryNotBefore, deadline)
        let blocked = try await store.retryPreparation(key: key, itemID: "item")
        XCTAssertEqual(blocked.outgoing.first, item)
        let edited = try await store.editOutgoing(
            key: key, itemID: "item", text: "new caption", replyToMessage: nil,
            attachments: [slot], compressionEnabled: true)
        XCTAssertEqual(edited.outgoing.first?.attachments.first?.retryNotBefore, deadline)
        let replaced = try await store.editOutgoing(
            key: key, itemID: "item", text: "new caption", replyToMessage: nil,
            attachments: [slot], compressionEnabled: false)
        XCTAssertNotEqual(replaced.outgoing.first?.attachments.first?.generation, slot.generation)
        XCTAssertNil(replaced.outgoing.first?.attachments.first?.retryNotBefore)
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
            chatID: "chat", text: caption, editRevision: 1, updatedAt: Date(),
            replyToMessage: reply,
            linkPreviews: metadata.linkPreviews)
        var file = try image(directory, id: "file")
        file.preservesOriginal = true
        file.width = 0
        file.height = 0
        file.preparedPath = file.sourcePath
        file.attachmentID = "uploaded-file"
        let attached = try await store.setDraftAttachments(
            key: key, attachments: [file], compressionEnabled: false)
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
        _ = try await store.saveDraft(
            chatID: "chat", text: "a draft", editRevision: 1, updatedAt: date)
        _ = try await store.saveDraft(chatID: "chat", text: "", editRevision: 2, updatedAt: date)
        let hasEmptyDraft = try await store.hasWork()
        XCTAssertFalse(hasEmptyDraft)
        _ = try await store.saveDraft(
            chatID: "chat", text: "new draft", editRevision: 3, updatedAt: date)
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

    func testReopenRetainsUncappedListsAndIndexedHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ConversationKey(chatID: "history")
        do {
            let store = try ChahuaLocalStore(directory: directory, userID: 17)
            let epoch = try await store.cacheEpoch()
            var seen = Set<ConversationKey>()
            for page in (0..<21).reversed() {
                let lower = UInt64(page * 50 + 1)
                try await store.cacheHistory(
                    key, query: ListMessagesQuery(before: page == 20 ? nil : MessageID(lower + 50)),
                    response: ListMessagesResponse(
                        messages: (lower..<(lower + 50)).map { historyMessage($0, key: key) },
                        olderCursor: page == 0 ? nil : MessageID(lower)), epoch: epoch)
                if page <= 4 {
                    let items = (0..<50).map { offset -> CachedConversation in
                        let id = page * 50 + offset
                        return .chat(
                            ChatListItem(
                                id: "\(id)", lastMessageAt: Date(timeIntervalSince1970: Double(id)),
                                unreadCount: 7, peerLastReadMessageId: MessageID(2),
                                archived: false, kind: .dm))
                    }
                    seen.formUnion(items.map(\.key))
                    try await store.cacheList(
                        .activeChats, items: items, seen: page == 0 ? seen : nil, epoch: epoch)
                }
            }
            let unsigned = ConversationKey(chatID: "unsigned")
            let values: [UInt64] = [9, 10, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max]
            try await store.cacheHistory(
                unsigned, query: ListMessagesQuery(),
                response: ListMessagesResponse(
                    messages: values.reversed().map { historyMessage($0, key: unsigned) }),
                epoch: epoch)
            let noWork = try await store.hasWork()
            XCTAssertFalse(noWork)
        }
        let reopened = try ChahuaLocalStore(directory: directory, userID: 17)
        var page = try await reopened.cachedHistory(key)
        XCTAssertEqual(page.messages.map(\.id.rawValue), Array(1001...1050))
        var count = page.messages.count
        while page.hasOlder, let first = page.messages.first {
            page = try await reopened.cachedHistory(key, position: .before(first.id))
            count += page.messages.count
        }
        XCTAssertEqual(count, 1050)
        XCTAssertEqual(page.messages.first?.id, MessageID(1))
        let unsigned = try await reopened.cachedHistory(ConversationKey(chatID: "unsigned"))
        XCTAssertEqual(
            unsigned.messages.map(\.id.rawValue),
            [9, 10, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
        let firstListPage = try await reopened.cachedList(.activeChats)
        var list = try XCTUnwrap(firstListPage)
        var keys = list.items.map(\.key.chatID)
        while let next = list.next {
            let nextPage = try await reopened.cachedList(.activeChats, after: next)
            list = try XCTUnwrap(nextPage)
            keys += list.items.map(\.key.chatID)
        }
        XCTAssertTrue(list.complete)
        XCTAssertEqual(keys, (0..<250).reversed().map(String.init))
        if case .chat(let item) = list.items.first {
            XCTAssertEqual(item.peerLastReadMessageId, MessageID(2))
            XCTAssertEqual(item.unreadCount, 7)
        } else {
            XCTFail("Expected a cached chat")
        }
    }

    func testHistoryGapAndEmptyLatestReplayDoNotInventContinuity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await store.cacheEpoch()
        let key = ConversationKey(chatID: "chat")
        try await store.cacheHistory(
            key, query: ListMessagesQuery(around: MessageID(10)),
            response: ListMessagesResponse(
                messages: [historyMessage(10, key: key)], newerCursor: MessageID(10)), epoch: epoch)
        try await store.cacheHistory(
            key, query: ListMessagesQuery(),
            response: ListMessagesResponse(
                messages: [historyMessage(50, key: key)], olderCursor: MessageID(50)), epoch: epoch)
        let separate = try await store.cachedHistory(key)
        XCTAssertEqual(separate.messages.map(\.id), [MessageID(50)])
        XCTAssertTrue(separate.hasOlderSection)
        let older = try await store.cachedHistory(key, position: .previousSection(MessageID(50)))
        XCTAssertEqual(older.messages.map(\.id), [MessageID(10)])
        try await store.cacheHistory(
            key, query: ListMessagesQuery(before: MessageID(50)),
            response: ListMessagesResponse(messages: [
                historyMessage(30, key: key), historyMessage(10, key: key),
            ]),
            epoch: epoch)
        let joined = try await store.cachedHistory(key)
        XCTAssertEqual(joined.messages.map(\.id.rawValue), [10, 30, 50])
        XCTAssertFalse(joined.hasOlderSection)
        try await store.cacheHistory(
            key, query: ListMessagesQuery(), response: ListMessagesResponse(messages: []),
            replay: [.create(historyMessage(61, key: key), key)], epoch: epoch)
        let replayed = try await store.cachedHistory(key)
        XCTAssertEqual(replayed.messages.map(\.id), [MessageID(61)])
        XCTAssertEqual(replayed.context?.verifiedEmpty, false)
    }

    func testDeletionRedactsQuotesAndCannotRestoreLateCachedMembership() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let root = ConversationKey(chatID: "chat")
        let thread = ConversationKey(chatID: "chat", threadID: "20")
        let deleted = historyMessage(20, key: root)
        let reply = MessageResponse(
            id: MessageID(30), chatId: root.chatID, clientGeneratedId: "reply", messageType: .text,
            sender: deleted.sender, createdAt: deleted.createdAt, message: "quoted it",
            replyToMessage: deleted.replyPreview)
        let original = ListMessagesResponse(messages: [deleted, reply])
        let epoch = try await store.cacheEpoch()
        try await store.cacheHistory(root, query: .init(), response: original, epoch: epoch)
        try await store.cacheHistory(
            thread, query: .init(threadID: "20"),
            response: ListMessagesResponse(messages: [deleted]), epoch: epoch)
        _ = try await store.saveDraft(
            chatID: root.chatID, text: "draft", editRevision: 1, updatedAt: Date(),
            replyToMessage: deleted.replyPreview)
        try await store.cacheChange(.delete(chatID: root.chatID, ids: [deleted.id]), epoch: epoch)
        try await store.cacheHistory(root, query: .init(), response: original, epoch: epoch)

        let saved = try await store.cachedHistory(root)
        let savedThread = try await store.cachedHistory(thread)
        let drafts = try await store.load()
        XCTAssertEqual(saved.messages.map(\.id), [reply.id])
        XCTAssertEqual(saved.messages.first?.replyToMessage?.isDeleted, true)
        XCTAssertNil(saved.messages.first?.replyToMessage?.message)
        XCTAssertEqual(savedThread.messages.first?.isDeleted, true)
        XCTAssertNil(savedThread.messages.first?.message)
        XCTAssertEqual(drafts.first?.draft.replyToMessage?.isDeleted, true)
        XCTAssertNil(drafts.first?.draft.replyToMessage?.message)
    }

    func testSyncBatchWithWrongFromLeavesRowsAndCheckpointUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await store.cacheEpoch()
        let key = ConversationKey(chatID: "chat")
        let original = historyMessage(20, key: key)
        try await store.resetSyncChat(
            chatID: key.chatID, cursor: "baseline", purge: false, epoch: epoch)
        let accepted = try await store.cacheHistory(
            key, query: .init(), response: .init(messages: [original]), at: "baseline", epoch: epoch
        )
        XCTAssertTrue(accepted)
        let bytesBefore = try await store.cachedMessageBytes()

        let result = try await store.commitSyncBatch(
            chatID: key.chatID, from: "wrong", to: "later",
            changes: [
                .upsert(message: original.replacingMessageText("wrong edit"), appeared: false),
                .upsert(message: historyMessage(30, key: key), appeared: true),
            ], epoch: epoch)
        guard case .mismatch = result else { return XCTFail("Expected a cursor mismatch") }
        let saved = try await store.cachedHistory(key)
        let bytesAfter = try await store.cachedMessageBytes()
        let manifest = try await store.syncResumeManifest(epoch: epoch)
        XCTAssertEqual(saved.messages, [original])
        XCTAssertEqual(bytesAfter, bytesBefore)
        XCTAssertTrue(saved.syncLatest)
        XCTAssertEqual(manifest, [MessageSyncCheckpoint(chatID: key.chatID, cursor: "baseline")])
    }

    func testSyncBatchRollsBackRowsAndCheckpointOnStorageFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await store.cacheEpoch()
        let key = ConversationKey(chatID: "chat")
        let original = historyMessage(20, key: key)
        let edited = original.replacingMessageText("updated")
        let arrival = historyMessage(30, key: key)
        let changes: [MessageSyncChange] = [
            .upsert(message: edited, appeared: false),
            .upsert(message: arrival, appeared: true),
        ]
        try await store.resetSyncChat(
            chatID: key.chatID, cursor: "baseline", purge: false, epoch: epoch)
        let accepted = try await store.cacheHistory(
            key, query: .init(), response: .init(messages: [original]), at: "baseline", epoch: epoch
        )
        XCTAssertTrue(accepted)
        let bytesBefore = try await store.cachedMessageBytes()
        try await store.database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_sync_batch AFTER INSERT ON cached_member
                    BEGIN SELECT RAISE(ABORT, 'sync membership blocked'); END
                    """)
        }

        do {
            _ = try await store.commitSyncBatch(
                chatID: key.chatID, from: "baseline", to: "later", changes: changes, epoch: epoch)
            XCTFail("The membership write must fail after the cached bodies have been written")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.message, "sync membership blocked")
        }
        let rolledBack = try await store.cachedHistory(key)
        let bytesAfter = try await store.cachedMessageBytes()
        let manifest = try await store.syncResumeManifest(epoch: epoch)
        XCTAssertEqual(rolledBack.messages, [original])
        XCTAssertEqual(bytesAfter, bytesBefore)
        XCTAssertEqual(manifest, [MessageSyncCheckpoint(chatID: key.chatID, cursor: "baseline")])

        try await store.database.write { db in try db.execute(sql: "DROP TRIGGER fail_sync_batch") }
        let retry = try await store.commitSyncBatch(
            chatID: key.chatID, from: "baseline", to: "later", changes: changes, epoch: epoch)
        guard case .committed = retry else {
            return XCTFail("The unchanged checkpoint must allow a retry")
        }
        let saved = try await store.cachedHistory(key)
        let advanced = try await store.syncResumeManifest(epoch: epoch)
        XCTAssertEqual(saved.messages, [edited, arrival])
        XCTAssertEqual(advanced, [MessageSyncCheckpoint(chatID: key.chatID, cursor: "later")])
    }

    func testStaleSyncPageCannotOverwriteReplayOrCertifyTail() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await store.cacheEpoch()
        let key = ConversationKey(chatID: "chat")
        let original = historyMessage(20, key: key)
        let edited = original.replacingMessageText("updated")
        try await store.resetSyncChat(
            chatID: key.chatID, cursor: "baseline", purge: false, epoch: epoch)
        try await store.cacheHistory(
            key, query: .init(), response: .init(messages: [original]), epoch: epoch)
        let result = try await store.commitSyncBatch(
            chatID: key.chatID, from: "baseline", to: "later",
            changes: [.upsert(message: edited, appeared: false)], epoch: epoch)
        guard case .committed = result else { return XCTFail("Expected the edit to commit") }

        let stale = try await store.cacheHistory(
            key, query: .init(), response: .init(messages: [original]), at: "baseline", epoch: epoch
        )
        XCTAssertFalse(stale)
        let saved = try await store.cachedHistory(key)
        XCTAssertEqual(saved.messages, [edited])
        XCTAssertFalse(saved.syncLatest)

        let fresh = try await store.cacheHistory(
            key, query: .init(), response: .init(messages: [edited]), at: "later", epoch: epoch)
        XCTAssertTrue(fresh)
        let certified = try await store.cachedHistory(key)
        XCTAssertEqual(certified.messages, [edited])
        XCTAssertTrue(certified.syncLatest)
    }

    func testNonPurgeSyncResetKeepsSavedRangeButBreaksContinuity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await store.cacheEpoch()
        let key = ConversationKey(chatID: "chat")
        let thread = ConversationKey(chatID: key.chatID, threadID: "20")
        let original = historyMessage(20, key: key)
        try await store.resetSyncChat(
            chatID: key.chatID, cursor: "baseline", purge: false, epoch: epoch)
        let accepted = try await store.cacheHistory(
            key, query: .init(), response: .init(messages: [original]), at: "baseline", epoch: epoch
        )
        let acceptedEmpty = try await store.cacheHistory(
            thread, query: .init(threadID: "20"), response: .init(messages: []), at: "baseline",
            epoch: epoch)
        XCTAssertTrue(accepted)
        XCTAssertTrue(acceptedEmpty)
        let verified = try await store.cachedHistory(key)
        let empty = try await store.cachedHistory(thread)
        XCTAssertTrue(verified.syncLatest)
        XCTAssertTrue(empty.syncLatest)
        XCTAssertEqual(empty.context?.verifiedEmpty, true)

        let reset = try await store.resetSyncChat(
            chatID: key.chatID, cursor: "reset", purge: false, epoch: epoch)
        XCTAssertTrue(reset)
        let saved = try await store.cachedHistory(key)
        let unverified = try await store.cachedHistory(thread)
        let manifest = try await store.syncResumeManifest(epoch: epoch)
        XCTAssertEqual(saved.messages, [original])
        XCTAssertFalse(saved.syncLatest)
        XCTAssertFalse(unverified.syncLatest)
        XCTAssertEqual(unverified.context?.verifiedEmpty, false)
        XCTAssertEqual(manifest, [MessageSyncCheckpoint(chatID: key.chatID, cursor: "reset")])

        let arrival = historyMessage(30, key: key)
        let result = try await store.commitSyncBatch(
            chatID: key.chatID, from: "reset", to: "later",
            changes: [.upsert(message: arrival, appeared: true)],
            epoch: epoch)
        guard case .committed = result else {
            return XCTFail("Expected replay from the reset cursor to commit")
        }
        let latest = try await store.cachedHistory(key)
        let historical = try await store.cachedHistory(key, position: .around(original.id))
        XCTAssertEqual(latest.messages, [arrival])
        XCTAssertFalse(latest.syncLatest)
        XCTAssertEqual(historical.messages, [original])
        XCTAssertFalse(historical.syncLatest)
    }

    func testClearHistoryFencesWritesAndLeavesDraftAttachmentAndSubmittedWork() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await store.cacheEpoch()
        let key = ConversationKey(chatID: "chat")
        let attachment = try image(directory, id: "draft-attachment")
        _ = try await store.setDraftAttachments(
            key: key, attachments: [attachment], compressionEnabled: true)
        _ = try await store.saveDraft(
            chatID: key.chatID, text: "keep draft", editRevision: 1, updatedAt: Date())
        _ = try await store.enqueueIndependentText(
            chatID: key.chatID, clientGeneratedID: "keep outgoing", text: "keep", enqueuedAt: Date()
        )
        let response = ListMessagesResponse(messages: [historyMessage(20, key: key)])
        try await store.resetSyncChat(
            chatID: key.chatID, cursor: "baseline", purge: false, epoch: epoch)
        let accepted = try await store.cacheHistory(
            key, query: .init(), response: response, at: "baseline", epoch: epoch)
        XCTAssertTrue(accepted)
        let manifestBefore = try await store.syncResumeManifest(epoch: epoch)
        XCTAssertEqual(
            manifestBefore, [MessageSyncCheckpoint(chatID: key.chatID, cursor: "baseline")])
        try await store.recordPendingRead(key, base: MessageID(10), target: MessageID(20))
        let bytesBefore = try await store.cachedMessageBytes()
        XCTAssertGreaterThan(bytesBefore, 0)

        try await store.clearMessageHistory()
        let lateLegacyPage = try await store.cacheHistory(
            key, query: .init(), response: response, epoch: epoch)
        XCTAssertFalse(lateLegacyPage)
        let latePage = try await store.cacheHistory(
            key, query: .init(), response: response, at: "baseline", epoch: epoch)
        XCTAssertFalse(latePage)
        let staleBatch = try await store.commitSyncBatch(
            chatID: key.chatID, from: "baseline", to: "later",
            changes: [.upsert(message: historyMessage(30, key: key), appeared: true)], epoch: epoch)
        guard case .stale = staleBatch else {
            return XCTFail("Clearing history must fence older batches")
        }
        let newEpoch = try await store.cacheEpoch()
        let manifestAfter = try await store.syncResumeManifest(epoch: newEpoch)
        let cleared = try await store.cachedHistory(key)
        XCTAssertTrue(manifestAfter.isEmpty)
        XCTAssertTrue(cleared.messages.isEmpty)
        XCTAssertFalse(cleared.syncLatest)
        let bytesAfter = try await store.cachedMessageBytes()
        let snapshots = try await store.restore()
        let reads = try await store.pendingReads()
        XCTAssertEqual(bytesAfter, 0)
        XCTAssertEqual(snapshots.first?.draft.text, "keep draft")
        XCTAssertEqual(snapshots.first?.draft.attachments.map(\.id), [attachment.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.sourcePath))
        XCTAssertEqual(snapshots.flatMap(\.outgoing).map(\.clientGeneratedID), ["keep outgoing"])
        XCTAssertEqual(reads, [PendingRead(key: key, base: MessageID(10), target: MessageID(20))])
    }

    func testListSyncMigratesAndResumesStagingWithoutReplacingVisibleList() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = ChatListItem(id: "1", unreadCount: 3, archived: false, kind: .dm)
        do {
            let store = try ChahuaLocalStore(directory: directory, userID: 17)
            let epoch = try await store.cacheEpoch()
            try await store.cacheList(
                .activeChats, items: [.chat(old)], seen: [ConversationKey(chatID: "1")],
                epoch: epoch)
            _ = try await store.saveDraft(
                chatID: "1", text: "keep draft", editRevision: 1, updatedAt: Date())
        }
        try editMigrationDatabase(directory) { db in
            try db.drop(table: "list_sync_stage")
            try db.drop(table: "list_sync_state")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v14_list_sync'")
        }
        let latest = historyMessage(20, key: ConversationKey(chatID: "2"))
        let replacement = ChatListItem(
            id: "2", lastMessageAt: latest.createdAt, unreadCount: 9,
            lastMessage: latest.replyPreview, archived: false, kind: .dm)
        do {
            let store = try ChahuaLocalStore(directory: directory, userID: 17)
            let epoch = try await store.cacheEpoch()
            let initial = try await store.listSyncState(epoch: epoch)
            XCTAssertEqual(initial, ListSyncState())
            _ = try await applyListPage(
                store, listDifference("baseline", complete: false, reset: "noBaseline"),
                request: .forcedStart)
            let stage = try await applyListPage(
                store,
                listDifference(
                    "enumerated", complete: false, chats: [replacement], latestMessages: [latest]),
                request: .staged)
            XCTAssertEqual(stage.stagingToken, "enumerated")
            XCTAssertNil(stage.installedToken)
            let visible = try await store.cachedList(.activeChats)
            XCTAssertEqual(visible?.items.map(\.key), [ConversationKey(chatID: "1")])
            let hiddenSeed = try await store.cachedHistory(ConversationKey(chatID: "2"))
            XCTAssertTrue(hiddenSeed.messages.isEmpty)
        }
        let reopened = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await reopened.cacheEpoch()
        let resumed = try await reopened.listSyncState(epoch: epoch)
        XCTAssertEqual(resumed.stagingToken, "enumerated")
        _ = try await applyListPage(
            reopened, listDifference("catch-up", complete: false), request: .staged)
        let installed = try await applyListPage(
            reopened, listDifference("catch-up", complete: true), request: .staged)
        XCTAssertEqual(installed.installedToken, "catch-up")
        XCTAssertNil(installed.stagingToken)
        XCTAssertEqual(installed.installedChatSettings, ChatSettings(showMembershipMessages: true))
        XCTAssertNotNil(installed.installedNotificationSettings)
        for scope in [
            CachedListScope.activeChats, .archivedChats, .activeThreads, .archivedThreads,
        ] {
            let saved = try await reopened.cachedList(scope)
            XCTAssertEqual(saved?.complete, true)
            XCTAssertEqual(
                saved?.items.map(\.key), scope == .activeChats ? [ConversationKey(chatID: "2")] : []
            )
        }
        let seed = try await reopened.cachedHistory(ConversationKey(chatID: "2"))
        XCTAssertEqual(seed.messages, [latest])
        XCTAssertFalse(seed.syncLatest)
        XCTAssertEqual(seed.syncOlderCursor, latest.id)
        let drafts = try await reopened.load()
        XCTAssertEqual(drafts.first(where: { $0.chatID == "1" })?.draft.text, "keep draft")
    }

    func testListSyncComparesFullStateAndEpochIncludingForcedStart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await store.cacheEpoch()
        let original = try await store.listSyncState(epoch: epoch)
        let state = try await applyListPage(
            store, listDifference("B", complete: false, reset: "unknown-reason"),
            request: .forcedStart)
        let staleStart = try await store.commitListDifference(
            listDifference("wrong", complete: false, reset: "expired"),
            expected: original, request: .forcedStart, epoch: epoch)
        XCTAssertEqual(staleStart, .mismatch)
        let wrongSettings = ListSyncState(
            stagingToken: state.stagingToken,
            stagedChatSettings: ChatSettings(showMembershipMessages: false),
            stagedNotificationSettings: state.stagedNotificationSettings)
        let mismatch = try await store.commitListDifference(
            listDifference("wrong", complete: true), expected: wrongSettings,
            request: .staged, epoch: epoch)
        XCTAssertEqual(mismatch, .mismatch)
        let unchanged = try await store.listSyncState(epoch: epoch)
        XCTAssertEqual(unchanged, state)
        let resetAgain = try await applyListPage(
            store, listDifference("fresh", complete: false, reset: "epochChanged"),
            request: .staged)
        XCTAssertEqual(resetAgain.stagingToken, "fresh")
        _ = try await store.advanceCacheEpoch()
        let stale = try await store.commitListDifference(
            listDifference("stale", complete: true), expected: resetAgain,
            request: .staged, epoch: epoch)
        XCTAssertEqual(stale, .stale)
    }

    func testListSyncEmptyInstallAndLegacyInvalidationPreserveVisibleRows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        _ = try await applyListPage(
            store, listDifference("empty", complete: false, reset: "noBaseline"),
            request: .forcedStart)
        _ = try await applyListPage(
            store, listDifference("empty", complete: true), request: .staged)
        for scope in [
            CachedListScope.activeChats, .archivedChats, .activeThreads, .archivedThreads,
        ] {
            let page = try await store.cachedList(scope)
            XCTAssertEqual(page?.complete, true)
            XCTAssertEqual(page?.items.count, 0)
        }
        let chat = ChatListItem(id: "1", unreadCount: 7, archived: false, kind: .dm)
        _ = try await applyListPage(
            store, listDifference("delta", complete: true, chats: [chat]), request: .installed)
        let settings = ChatSettings(showMembershipMessages: false, showUnreadMessageCount: true)
        let notifications = NotificationSettingsResponse(
            muteGroupChatsByDefault: true, muteDirectChatsByDefault: true)
        let changed = try await applyListPage(
            store,
            listDifference(
                "delta", complete: true, chatSettings: settings, notificationSettings: notifications
            ),
            request: .installed)
        XCTAssertEqual(changed.installedChatSettings, settings)
        XCTAssertEqual(changed.installedNotificationSettings, notifications)
        _ = try await applyListPage(
            store, listDifference("rebuild", complete: false, reset: "tooLarge"),
            request: .forcedStart)
        let epoch = try await store.cacheEpoch()
        try await store.invalidateListSync(epoch: epoch)
        let invalidated = try await store.listSyncState(epoch: epoch)
        XCTAssertNil(invalidated.installedToken)
        XCTAssertNil(invalidated.stagingToken)
        XCTAssertNil(invalidated.stagedChatSettings)
        XCTAssertNil(invalidated.stagedNotificationSettings)
        let visible = try await store.cachedList(.activeChats)
        XCTAssertEqual(visible?.items.map(\.key.chatID), ["1"])
    }

    func testListDeltaJoinsSelectedSidecarsPreservesUnreadAndReplacesArchiveKey() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await store.cacheEpoch()
        let first = historyMessage(20, key: ConversationKey(chatID: "1"))
        let second = historyMessage(30, key: ConversationKey(chatID: "2"))
        let canonical = first.replacingMessageText("newer canonical edit")
        try await store.cacheHistory(
            ConversationKey(chatID: "1"), query: .init(),
            response: .init(messages: [canonical]), epoch: epoch)
        let firstRow = ChatListItem(
            id: "1", lastMessageAt: first.createdAt, unreadCount: 7, unreadMentions: 2,
            unreadReactions: 3, lastReadMessageId: MessageID(10),
            peerLastReadMessageId: MessageID(12), lastMessage: first.replyPreview,
            archived: false, kind: .dm)
        let secondRow = ChatListItem(
            id: "2", lastMessageAt: second.createdAt, unreadCount: 4,
            lastMessage: second.replyPreview, archived: false, kind: .dm)
        let thread = listThread(chatID: "1", root: first.replyPreview)
        _ = try await applyListPage(
            store, listDifference("B", complete: false, reset: "noBaseline"),
            request: .forcedStart)
        _ = try await applyListPage(
            store,
            listDifference(
                "installed", complete: true, chats: [firstRow, secondRow], threads: [thread],
                latestMessages: [second, first]), request: .staged)
        let savedFirst = try await store.cachedHistory(ConversationKey(chatID: "1"))
        let savedSecond = try await store.cachedHistory(ConversationKey(chatID: "2"))
        XCTAssertEqual(savedFirst.messages, [canonical])
        XCTAssertEqual(savedSecond.messages, [second])
        XCTAssertFalse(savedSecond.syncLatest)
        let manifest = try await store.syncResumeManifest(epoch: epoch)
        XCTAssertTrue(manifest.allSatisfy { $0.cursor == nil })

        // An ordinary delta may omit the parent; this does not remove its thread.
        let moved = ChatListItem(
            id: "1", unreadCount: 7, unreadMentions: 2, unreadReactions: 3,
            lastReadMessageId: MessageID(10), peerLastReadMessageId: MessageID(12),
            archived: true, kind: .dm)
        _ = try await applyListPage(
            store, listDifference("moved", complete: true, chats: [moved]),
            request: .installed)
        let reopened = try ChahuaLocalStore(directory: directory, userID: 17)
        let active = try await reopened.cachedList(.activeChats)
        let archived = try await reopened.cachedList(.archivedChats)
        let threads = try await reopened.cachedList(.activeThreads)
        XCTAssertEqual(active?.items.map(\.key.chatID), ["2"])
        XCTAssertEqual(threads?.items.map(\.key), [ConversationKey(chatID: "1", threadID: "20")])
        guard case .thread(let restoredThread) = threads?.items.first else {
            return XCTFail("Expected a saved thread")
        }
        XCTAssertEqual(restoredThread.unreadCount, 5)
        XCTAssertEqual(restoredThread.unreadMentions, 2)
        XCTAssertEqual(restoredThread.unreadReactions, 1)
        XCTAssertEqual(restoredThread.peerLastReadMessageId, MessageID(11))
        guard case .chat(let restored) = archived?.items.first else {
            return XCTFail("Expected exactly one archived chat")
        }
        XCTAssertEqual(restored.unreadCount, 7)
        XCTAssertEqual(restored.unreadMentions, 2)
        XCTAssertEqual(restored.unreadReactions, 3)
        XCTAssertEqual(restored.peerLastReadMessageId, MessageID(12))
        XCTAssertNil(restored.lastMessage)
        let historyAfterClear = try await reopened.cachedHistory(ConversationKey(chatID: "1"))
        XCTAssertEqual(historyAfterClear.messages, [canonical])
    }

    func testListDeltaRemovesOnlyRequestedKeyAndParentRemovesArchivedChildren() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let first = historyMessage(20, key: ConversationKey(chatID: "1"))
        let second = historyMessage(30, key: ConversationKey(chatID: "1"))
        let chat = ChatListItem(id: "1", unreadCount: 1, archived: false, kind: .dm)
        _ = try await applyListPage(
            store, listDifference("B", complete: false, reset: "noBaseline"),
            request: .forcedStart)
        _ = try await applyListPage(
            store,
            listDifference(
                "installed", complete: true, chats: [chat],
                threads: [
                    listThread(chatID: "1", root: first.replyPreview),
                    listThread(chatID: "1", root: second.replyPreview, archived: true),
                ]), request: .staged)
        _ = try await applyListPage(
            store,
            listDifference(
                "unsubscribed", complete: true,
                removed: [ConversationRef(chatId: "1", threadId: first.id)]),
            request: .installed)
        let active = try await store.cachedList(.activeChats)
        let activeThreads = try await store.cachedList(.activeThreads)
        let archivedThreads = try await store.cachedList(.archivedThreads)
        XCTAssertEqual(active?.items.count, 1)
        XCTAssertEqual(activeThreads?.items.count, 0)
        XCTAssertEqual(archivedThreads?.items.count, 1)
        _ = try await applyListPage(
            store,
            listDifference(
                "removed", complete: true, removed: [ConversationRef(chatId: "1")]),
            request: .installed)
        let removedChat = try await store.cachedList(.activeChats)
        let removedChildren = try await store.cachedList(.archivedThreads)
        XCTAssertEqual(removedChat?.items.count, 0)
        XCTAssertEqual(removedChildren?.items.count, 0)
    }

    func testListSyncRejectsNonprogressAndMalformedSidecarsWithoutChangingState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let state = try await applyListPage(
            store, listDifference("B", complete: false, reset: "noBaseline"),
            request: .forcedStart)
        let epoch = try await store.cacheEpoch()
        let message = historyMessage(20, key: ConversationKey(chatID: "1"))
        let row = ChatListItem(
            id: "1", unreadCount: 1, lastMessage: message.replyPreview,
            archived: false, kind: .dm)
        let malformed = [
            listDifference("B", complete: false),
            listDifference("next", complete: true, latestMessages: [message]),
            listDifference(
                "next", complete: true, chats: [row],
                latestMessages: [historyMessage(21, key: ConversationKey(chatID: "1"))]),
            listDifference(
                "next", complete: true, chats: [row, row], latestMessages: [message]),
            listDifference(
                "next", complete: true, chats: [row], removed: [ConversationRef(chatId: "1")]),
        ]
        for page in malformed {
            do {
                _ = try await store.commitListDifference(
                    page, expected: state, request: .staged, epoch: epoch)
                XCTFail("Malformed pages must fail, not advance their token")
            } catch LocalStorageError.corruptRecord {
            }
            let after = try await store.listSyncState(epoch: epoch)
            XCTAssertEqual(after, state)
            let visible = try await store.cachedList(.activeChats)
            XCTAssertNil(visible)
        }
    }

    func testListSyncPromotionRollsBackRowsSidecarsAndTokenTogether() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await store.cacheEpoch()
        let old = ChatListItem(id: "1", unreadCount: 1, archived: false, kind: .dm)
        try await store.cacheList(
            .activeChats, items: [.chat(old)], seen: [ConversationKey(chatID: "1")],
            epoch: epoch)
        let message = historyMessage(20, key: ConversationKey(chatID: "2"))
        let new = ChatListItem(
            id: "2", unreadCount: 4, lastMessage: message.replyPreview,
            archived: false, kind: .dm)
        _ = try await applyListPage(
            store, listDifference("B", complete: false, reset: "noBaseline"),
            request: .forcedStart)
        let state = try await applyListPage(
            store,
            listDifference("staged", complete: false, chats: [new], latestMessages: [message]),
            request: .staged)
        try await store.database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_list_install AFTER UPDATE OF installed_token ON list_sync_state
                    BEGIN SELECT RAISE(ABORT, 'list install blocked'); END
                    """)
        }
        let final = listDifference("installed", complete: true)
        do {
            _ = try await store.commitListDifference(
                final, expected: state, request: .staged, epoch: epoch)
            XCTFail("The final token write must roll back the entire promotion")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.message, "list install blocked")
        }
        let after = try await store.listSyncState(epoch: epoch)
        let visible = try await store.cachedList(.activeChats)
        let seed = try await store.cachedHistory(ConversationKey(chatID: "2"))
        XCTAssertEqual(after, state)
        XCTAssertEqual(visible?.items.map(\.key.chatID), ["1"])
        XCTAssertTrue(seed.messages.isEmpty)
        try await store.database.write { db in try db.execute(sql: "DROP TRIGGER fail_list_install")
        }
        let retry = try await store.commitListDifference(
            final, expected: state, request: .staged, epoch: epoch)
        XCTAssertEqual(retry, .committed)
        let installed = try await store.cachedList(.activeChats)
        let installedSeed = try await store.cachedHistory(ConversationKey(chatID: "2"))
        XCTAssertEqual(installed?.items.map(\.key.chatID), ["2"])
        XCTAssertEqual(installedSeed.messages, [message])
    }

    func testStagedRemovalsAndSecondResetDiscardRowsAndSidecars() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let first = historyMessage(20, key: ConversationKey(chatID: "1"))
        let second = historyMessage(30, key: ConversationKey(chatID: "2"))
        let rows = [
            ChatListItem(
                id: "1", unreadCount: 1, lastMessage: first.replyPreview,
                archived: false, kind: .dm),
            ChatListItem(
                id: "2", unreadCount: 1, lastMessage: second.replyPreview,
                archived: false, kind: .dm),
        ]
        _ = try await applyListPage(
            store, listDifference("B", complete: false, reset: "noBaseline"),
            request: .forcedStart)
        _ = try await applyListPage(
            store,
            listDifference(
                "enumerated", complete: false, chats: rows,
                threads: [
                    listThread(chatID: "1", root: first.replyPreview, archived: true),
                    listThread(chatID: "2", root: second.replyPreview),
                ], latestMessages: [second, first]), request: .staged)
        _ = try await applyListPage(
            store,
            listDifference(
                "installed", complete: true,
                removed: [
                    ConversationRef(chatId: "1"), ConversationRef(chatId: "2", threadId: second.id),
                ]), request: .staged)
        let installed = try await store.cachedList(.activeChats)
        let removedParentSidecar = try await store.cachedHistory(ConversationKey(chatID: "1"))
        XCTAssertEqual(installed?.items.map(\.key.chatID), ["2"])
        XCTAssertTrue(removedParentSidecar.messages.isEmpty)
        for scope in [CachedListScope.activeThreads, .archivedThreads] {
            let page = try await store.cachedList(scope)
            XCTAssertEqual(page?.items.count, 0)
        }
        _ = try await applyListPage(
            store, listDifference("rebuild", complete: false, reset: "expired"),
            request: .forcedStart)
        _ = try await applyListPage(
            store,
            listDifference(
                "partial", complete: false, chats: [rows[0]], latestMessages: [first]),
            request: .staged)
        let reset = try await applyListPage(
            store, listDifference("fresh", complete: false, reset: "accountChanged"),
            request: .staged)
        XCTAssertEqual(reset.installedToken, "installed")
        XCTAssertEqual(reset.stagingToken, "fresh")
        let stillVisible = try await store.cachedList(.activeChats)
        XCTAssertEqual(stillVisible?.items.map(\.key.chatID), ["2"])
        _ = try await applyListPage(
            store, listDifference("fresh", complete: true), request: .staged)
        let empty = try await store.cachedList(.activeChats)
        let discardedSidecar = try await store.cachedHistory(ConversationKey(chatID: "1"))
        XCTAssertEqual(empty?.items.count, 0)
        XCTAssertTrue(discardedSidecar.messages.isEmpty)
        // Replacing list membership never removes unrelated saved history.
        let retainedHistory = try await store.cachedHistory(ConversationKey(chatID: "2"))
        XCTAssertEqual(retainedHistory.messages, [second])
    }

    func testListPromotionRechecksLivePolicyTombstonesAndRevocation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let membership = MessageResponse(
            id: MessageID(20), chatId: "1", clientGeneratedId: "membership", messageType: .text,
            sender: User(uid: 17, gender: 0, name: nil, avatarUrl: nil, userGroup: nil),
            createdAt: Date(timeIntervalSince1970: 1), systemKind: .memberJoined)
        let deleted = historyMessage(30, key: ConversationKey(chatID: "2"))
        let revoked = historyMessage(40, key: ConversationKey(chatID: "3"))
        do {
            let store = try ChahuaLocalStore(directory: directory, userID: 17)
            let epoch = try await store.cacheEpoch()
            _ = try await applyListPage(
                store, listDifference("B", complete: false, reset: "noBaseline"),
                request: .forcedStart)
            _ = try await applyListPage(
                store,
                listDifference(
                    "staged", complete: false,
                    chats: [
                        ChatListItem(
                            id: "1", unreadCount: 1, lastMessage: membership.replyPreview,
                            archived: false, kind: .group,
                            membershipMessagePolicy: .init(visibility: .members, canView: true)),
                        ChatListItem(
                            id: "2", unreadCount: 1, lastMessage: deleted.replyPreview,
                            archived: false, kind: .dm),
                        ChatListItem(
                            id: "3", unreadCount: 1, lastMessage: revoked.replyPreview,
                            archived: false, kind: .dm),
                    ], latestMessages: [membership, deleted, revoked]),
                request: .staged)
            try await store.invalidateCachedPolicy(
                chatID: "1", policy: .init(visibility: .nobody, canView: false),
                settings: nil, epoch: epoch)
            try await store.cacheChange(.delete(chatID: "2", ids: [deleted.id]), epoch: epoch)
            try await store.purgeCachedChat("3", epoch: epoch)
        }
        // Restart must not revive stale policy or staged sidecars on promotion.
        let reopened = try ChahuaLocalStore(directory: directory, userID: 17)
        _ = try await applyListPage(
            reopened, listDifference("installed", complete: true), request: .staged)
        let visible = try await reopened.cachedList(.activeChats)
        XCTAssertEqual(Set(visible?.items.map(\.key.chatID) ?? []), ["1", "2"])
        for item in visible?.items ?? [] {
            guard case .chat(let chat) = item else { return XCTFail("Expected chats") }
            if chat.id == "1" {
                XCTAssertNil(chat.lastMessage)
                XCTAssertEqual(chat.membershipMessagePolicy?.canView, false)
            } else {
                XCTAssertEqual(chat.lastMessage?.isDeleted, true)
                XCTAssertNil(chat.lastMessage?.message)
            }
        }
        for chatID in ["1", "2", "3"] {
            let history = try await reopened.cachedHistory(ConversationKey(chatID: chatID))
            XCTAssertTrue(history.messages.isEmpty)
        }
    }

    func testLiveListSettingsPersistAndFenceHeldPage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let epoch = try await store.cacheEpoch()
        let held = try await applyListPage(
            store, listDifference("B", complete: false, reset: "noBaseline"),
            request: .forcedStart)
        let notifications = NotificationSettingsResponse(
            muteGroupChatsByDefault: true, muteDirectChatsByDefault: true)
        let settings = ChatSettings(showMembershipMessages: false, showUnreadMessageCount: true)
        try await store.cacheListNotificationSettings(notifications, epoch: epoch)
        try await store.invalidateCachedPolicy(
            chatID: nil, policy: nil, settings: settings, epoch: epoch)
        let stale = try await store.commitListDifference(
            listDifference("wrong", complete: true), expected: held,
            request: .staged, epoch: epoch)
        XCTAssertEqual(stale, .mismatch)
        let reopened = try ChahuaLocalStore(directory: directory, userID: 17)
        let restored = try await reopened.listSyncState(epoch: epoch)
        XCTAssertEqual(restored.stagingToken, "B")
        XCTAssertEqual(restored.installedChatSettings, settings)
        XCTAssertEqual(restored.stagedChatSettings, settings)
        XCTAssertEqual(restored.installedNotificationSettings, notifications)
        XCTAssertEqual(restored.stagedNotificationSettings, notifications)
        _ = try await store.advanceCacheEpoch()
        try await store.cacheListNotificationSettings(
            NotificationSettingsResponse(
                muteGroupChatsByDefault: false, muteDirectChatsByDefault: false), epoch: epoch)
        let newEpoch = try await store.cacheEpoch()
        let afterStaleWrite = try await store.listSyncState(epoch: newEpoch)
        XCTAssertEqual(afterStaleWrite.installedNotificationSettings, notifications)
    }

    func testReceiptProgressUpdatesInstalledAndStagedRowsWithoutAdvancingToken() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let chat = ChatListItem(
            id: "1", unreadCount: 5, peerLastReadMessageId: MessageID(8),
            archived: false, kind: .dm)
        let epoch = try await store.cacheEpoch()
        try await store.cacheList(.activeChats, items: [.chat(chat)], epoch: epoch)
        _ = try await applyListPage(
            store, listDifference("B", complete: false, reset: "noBaseline"), request: .forcedStart)
        _ = try await applyListPage(
            store, listDifference("C", complete: false, chats: [chat]), request: .staged)
        try await store.cacheListReceipt(MessageID(9), for: .init(chatID: "1"), epoch: epoch)
        let state = try await store.listSyncState(epoch: epoch)
        XCTAssertEqual(state.stagingToken, "C")
        let installed = try await store.cachedList(.activeChats)
        guard case .chat(let current)? = installed?.items.first else {
            return XCTFail("Expected installed chat")
        }
        XCTAssertEqual(current.peerLastReadMessageId, MessageID(9))
        _ = try await applyListPage(
            store, listDifference("D", complete: true), request: .staged)
        let reopened = try ChahuaLocalStore(directory: directory, userID: 17)
        let promoted = try await reopened.cachedList(.activeChats)
        guard case .chat(let row)? = promoted?.items.first else {
            return XCTFail("Expected promoted chat")
        }
        XCTAssertEqual(row.peerLastReadMessageId, MessageID(9))
        XCTAssertEqual(row.unreadCount, 5)
    }

    func testReceiptRevocationSurvivesStagingPromotionAndReopen() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory, userID: 17)
        let chat = ChatListItem(
            id: "1", unreadCount: 5, unreadMentions: 2, unreadReactions: 3,
            peerLastReadMessageId: MessageID(8), archived: false, kind: .dm)
        let epoch = try await store.cacheEpoch()
        try await store.cacheList(.activeChats, items: [.chat(chat)], epoch: epoch)
        _ = try await applyListPage(
            store, listDifference("B", complete: false, reset: "noBaseline"), request: .forcedStart)
        _ = try await applyListPage(
            store, listDifference("C", complete: false, chats: [chat]), request: .staged)
        try await store.clearCachedListReceipts(epoch: epoch)
        let visible = try await store.cachedList(.activeChats)
        guard case .chat(let redacted)? = visible?.items.first else {
            return XCTFail("Expected installed chat")
        }
        XCTAssertNil(redacted.peerLastReadMessageId)
        _ = try await applyListPage(
            store, listDifference("D", complete: true), request: .staged)
        let reopened = try ChahuaLocalStore(directory: directory, userID: 17)
        let promoted = try await reopened.cachedList(.activeChats)
        guard case .chat(let row)? = promoted?.items.first else {
            return XCTFail("Expected promoted chat")
        }
        XCTAssertNil(row.peerLastReadMessageId)
        XCTAssertEqual(row.unreadCount, 5)
        XCTAssertEqual(row.unreadMentions, 2)
        XCTAssertEqual(row.unreadReactions, 3)
    }

    private func applyListPage(
        _ store: ChahuaLocalStore, _ page: ConversationDifference, request: ListSyncRequest
    ) async throws -> ListSyncState {
        let epoch = try await store.cacheEpoch()
        let expected = try await store.listSyncState(epoch: epoch)
        let result = try await store.commitListDifference(
            page, expected: expected, request: request, epoch: epoch)
        XCTAssertEqual(result, .committed)
        return try await store.listSyncState(epoch: epoch)
    }

    private func listDifference(
        _ cursor: String, complete: Bool, reset: String? = nil,
        chatSettings: ChatSettings = ChatSettings(showMembershipMessages: true),
        notificationSettings: NotificationSettingsResponse = NotificationSettingsResponse(
            muteGroupChatsByDefault: false, muteDirectChatsByDefault: false),
        chats: [ChatListItem] = [], threads: [ThreadListItem] = [],
        latestMessages: [MessageResponse] = [], removed: [ConversationRef] = []
    ) -> ConversationDifference {
        ConversationDifference(
            cursor: cursor, complete: complete, reset: reset, chatSettings: chatSettings,
            notificationSettings: notificationSettings, chats: chats, threads: threads,
            latestMessages: latestMessages, removed: removed)
    }

    private func listThread(
        chatID: String, root: MessagePreview, archived: Bool = false
    ) -> ThreadListItem {
        ThreadListItem(
            chatId: chatID, chatName: "chat", threadRootMessage: root, replyCount: 4,
            lastReplyAt: root.createdAt, unreadCount: 5, unreadMentions: 2,
            unreadReactions: 1, peerLastReadMessageId: MessageID(11),
            subscribedAt: root.createdAt, archived: archived)
    }

    private func historyMessage(_ id: UInt64, key: ConversationKey) -> MessageResponse {
        MessageResponse(
            id: MessageID(id), chatId: key.chatID, clientGeneratedId: "\(id)", messageType: .text,
            sender: User(uid: 17, gender: 0, name: nil, avatarUrl: nil, userGroup: nil),
            createdAt: Date(timeIntervalSince1970: 1), message: "message \(id)",
            replyRootId: key.threadID)
    }

    private func editMigrationDatabase(_ directory: URL, _ update: (Database) throws -> Void) throws
    {
        let database = try DatabaseQueue(path: directory.appendingPathComponent("chat.sqlite").path)
        try database.write(update)
    }

    private func rewindMessageSyncMigration(_ db: Database) throws {
        try db.drop(table: "list_sync_stage")
        try db.drop(table: "list_sync_state")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v14_list_sync'")
        try db.drop(table: "sync_latest")
        try db.drop(table: "sync_checkpoint")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v13_message_sync'")
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
