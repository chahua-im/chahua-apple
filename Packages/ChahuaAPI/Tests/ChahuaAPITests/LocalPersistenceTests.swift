import Foundation
import GRDB
import XCTest

@testable import ChahuaAPI

final class LocalPersistenceTests: XCTestCase {
    func testForwardSelectionAndKeySurviveClaimRestoreRetryWithoutConsumingDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let draft = try await store!.saveDraft(
            chatID: "destination", threadID: "thread", text: "keep draft", editRevision: 1,
            updatedAt: Date(), replyToMessage: preview(id: 101))
        let sender = User(uid: 1, gender: 0, name: "Original", avatarUrl: nil, userGroup: nil)
        let source = MessageResponse(
            id: MessageID(9_007_199_254_740_993), chatId: "source", clientGeneratedId: "source-key",
            messageType: .placeholder, sender: sender, createdAt: Date(timeIntervalSince1970: 10),
            message: "pendingAudio",
            forwardedFrom: ForwardedFromInfo(
                sender: sender, originalChatId: "earlier", originalMessageId: MessageID(3)))
        let request = LocalForwardRequest(
            sourceChatID: "source", sources: [source], allowPlaceholders: true)
        let enqueued = try await store!.enqueueForward(
            chatID: "destination", threadID: "thread", senderID: 1, request: request)
        XCTAssertEqual(enqueued.draft, draft.draft)
        let pending = try XCTUnwrap(enqueued.outgoing.first)
        XCTAssertEqual(pending.forwardRequest, request)
        XCTAssertNil(pending.replyToMessage)
        let claim = try await store!.claimNext(chatID: "destination", threadID: "thread")
        XCTAssertEqual(claim.message?.clientGeneratedID, pending.clientGeneratedID)
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        let recovered = try XCTUnwrap(restored.first?.outgoing.first)
        XCTAssertEqual(recovered.clientGeneratedID, pending.clientGeneratedID)
        XCTAssertEqual(recovered.forwardRequest, request)
        XCTAssertTrue(recovered.dispatchClaimed)
        XCTAssertEqual(restored.first?.draft, draft.draft)
        _ = try await store!.fail(
            chatID: "destination", threadID: "thread", clientGeneratedID: pending.clientGeneratedID,
            speakingRestriction: .repliesOnly)
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restricted = try await store!.restore()
        XCTAssertEqual(restricted.first?.outgoing.first?.speakingRestriction, .repliesOnly)
        let retried = try await store!.retry(
            chatID: "destination", threadID: "thread", clientGeneratedID: pending.clientGeneratedID,
            scope: .message)
        XCTAssertEqual(retried.outgoing.first?.forwardRequest, request)
        XCTAssertEqual(retried.outgoing.first?.clientGeneratedID, pending.clientGeneratedID)
        XCTAssertNil(retried.outgoing.first?.speakingRestriction)
    }

    func testForwardedTextCannotBecomeEditableCompositionButCanBeRevoked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let source = MessageResponse(
            id: MessageID(1), chatId: "source", clientGeneratedId: "original",
            messageType: .text,
            sender: User(uid: 1, gender: 0, name: nil, avatarUrl: nil, userGroup: nil),
            createdAt: Date(), message: "immutable")
        let enqueued = try await store.enqueueForward(
            chatID: "destination", senderID: 1,
            request: LocalForwardRequest(sourceChatID: "source", sources: [source]))
        let pending = try XCTUnwrap(enqueued.outgoing.first)
        do {
            _ = try await store.editOutgoing(
                chatID: "destination", itemID: pending.clientGeneratedID, expectedRevision: 0,
                text: "changed", attachments: [])
            XCTFail("Forwarded text is not an editable ordinary message")
        } catch LocalStorageError.unsupportedMessageType {}
        let revoked = try await store.cancelOutgoing(
            chatID: "destination", itemID: pending.clientGeneratedID, expectedRevision: 0)
        XCTAssertTrue(revoked.outgoing.isEmpty)
    }

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
            replyToMessage: preview(id: 101))
        let sticker = MessageStickerResponse(
            id: "sticker", emoji: "wave", createdAt: Date(timeIntervalSince1970: 1),
            isFavorited: true,
            media: MessageStickerMediaResponse(
                id: "media", url: "https://example.test/sticker.webp",
                contentType: "image/webp", size: 123, width: 200, height: 150),
            name: "Wave", description: "A wave")
        let reply = preview(id: 102)
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
        let acknowledged = try await deliver(
            store!, chatID: "chat", threadID: "thread", itemID: "selected-sticker")
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
        XCTAssertEqual(imageClaim.message?.body.replyToId, MessageID(101))
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
            _ = try await store.editOutgoing(
                chatID: "chat", itemID: "sticker-send", expectedRevision: 0,
                text: "changed", attachments: [])
            XCTFail("A sticker must not be converted into an empty text draft")
        } catch LocalStorageError.unsupportedMessageType {}
        let restored = try await store.restore()
        XCTAssertNil(restored.first?.composingItem)
        XCTAssertEqual(restored.first?.outgoing.first?.body.messageType, .sticker)
        let revoked = try await store.cancelOutgoing(
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
        let reply = hasReplyContext ? preview(id: 103) : nil
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
        let reply = preview(id: 103)
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
        do {
            _ = try await store!.acceptCreate(
                confirmation(itemID: "id-1", text: "outgoing-1"), published: true)
            XCTFail("An acknowledgement for another conversation must be rejected")
        } catch LocalStorageError.staleDraft {}
        let wrongAcknowledgement = try await store!.claimNext(chatID: "chat", threadID: "one")
        XCTAssertEqual(wrongAcknowledgement.snapshot.outgoing.map(\.clientGeneratedID), ["id-1"])
        let acknowledged = try await deliver(
            store!, chatID: "chat", threadID: "one", itemID: "id-1")
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
        let reply = preview(id: 104)
        let nextReply = preview(id: 105)
        let choices = [LinkPreviewInput(url: "https://example.com", status: .disabled)]
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        _ = try await store!.saveDraft(
            chatID: "chat", text: "hello\n世界", editRevision: 1, updatedAt: Date(),
            replyToMessage: reply, linkPreviews: choices)
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        XCTAssertEqual(restored.first?.draft.text, "hello\n世界")
        XCTAssertEqual(restored.first?.draft.replyToMessage, reply)
        XCTAssertEqual(restored.first?.draft.linkPreviews, choices)
        let originalID = try XCTUnwrap(restored.first?.draft.itemID)
        let sent = try await store!.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "  hello\n世界  ",
            enqueuedAt: Date(), clearedDraftRevision: 2, replyToMessage: reply)
        XCTAssertEqual(sent.draft.text, "")
        XCTAssertNil(sent.draft.replyToMessage)
        XCTAssertEqual(sent.outgoing.first?.replyToMessage, reply)
        XCTAssertEqual(sent.outgoing.map(\.text), ["hello\n世界"])
        XCTAssertEqual(sent.draft.linkPreviews, [])
        XCTAssertEqual(sent.outgoing.first?.body.metadata?.linkPreviews, choices)
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
        _ = try await deliver(store!, chatID: "chat", itemID: "A")
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
        let reply = preview(id: 106)
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
        _ = try await store.cancelOutgoing(
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

    func testClaimBoundaryStaysFrozenThroughEditsFailureAndRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let disabled = MessageMetadataInput(
            linkPreviews: [.init(url: "https://example.com", status: .disabled)])
        let enabled = MessageMetadataInput(
            linkPreviews: [.init(url: "https://example.com", status: .enabled)])
        _ = try await store!.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "sealed", enqueuedAt: Date(),
            clearedDraftRevision: 1, replyToMessage: preview(id: 103), metadata: disabled)
        let claimed = try await store!.claimNext(chatID: "chat")
        let original = try XCTUnwrap(claimed.message)
        let edited = try await store!.editOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: original.editRevision,
            text: "replacement", attachments: [], metadata: enabled)
        XCTAssertEqual(edited.outgoing.first?.text, "replacement")
        XCTAssertEqual(edited.outgoing.first?.body, original.body)
        XCTAssertEqual(original.body.metadata, disabled)
        XCTAssertEqual(edited.outgoing.first?.metadata, enabled)
        XCTAssertEqual(edited.outgoing.first?.replyToMessage, original.replyToMessage)
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        _ = try await store!.restore()
        _ = try await store!.fail(chatID: "chat", clientGeneratedID: "A")
        _ = try await store!.retry(chatID: "chat", clientGeneratedID: "A", scope: .message)
        let retry = try await store!.claimNext(chatID: "chat")
        XCTAssertEqual(retry.message?.body, original.body)
        let accepted = try await store!.acceptCreate(
            confirmation(itemID: "A", text: "sealed"), published: true)
        XCTAssertEqual(accepted.disposition, .retained)
        let patch = try await store!.claimPatch(chatID: "chat", itemID: "A")
        XCTAssertEqual(patch.patch?.text, "replacement")
        XCTAssertEqual(patch.patch?.revision, original.editRevision + 1)
        XCTAssertEqual(patch.patch?.metadata, enabled)
    }

    func testConcurrentReleaseCreatesOneItemAndReleasedEditPreservesComposition() async throws {
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
        let edited = try await store.editOutgoing(
            chatID: "chat", itemID: pending.clientGeneratedID,
            expectedRevision: pending.editRevision, text: "edited older row", attachments: [])
        XCTAssertEqual(edited.composingItem, next.composingItem)
        XCTAssertEqual(edited.outgoing.first?.enqueueSequence, pending.enqueueSequence)
        let claim = try await store.claimNext(chatID: "chat")
        XCTAssertEqual(claim.message?.clientGeneratedID, pending.clientGeneratedID)
        XCTAssertEqual(
            claim.snapshot.composingItem?.clientGeneratedID, next.composingItem?.clientGeneratedID)
    }

    func testConcurrentClaimAndCancellationNeverResendCancelledIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let queued = try await store.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "race", enqueuedAt: Date(),
            clearedDraftRevision: 1)
        let pending = try XCTUnwrap(queued.outgoing.first)
        let claimTask = Task { try await store.claimNext(chatID: "chat") }
        let cancelTask = Task {
            try await store.cancelOutgoing(
                chatID: "chat", itemID: "A", expectedRevision: pending.editRevision)
        }
        let claim = try await claimTask.value
        let cancelled = try await cancelTask.value
        if let claimed = claim.message {
            XCTAssertEqual(claimed.body.clientGeneratedId, "A")
            XCTAssertTrue(try XCTUnwrap(cancelled.outgoing.first).isCancelled)
            XCTAssertEqual(cancelled.outgoing.first?.frozenCreate, claimed.frozenCreate)
        } else {
            XCTAssertTrue(cancelled.outgoing.isEmpty)
        }
        let reopened = try ChahuaLocalStore(directory: directory)
        _ = try await reopened.restore()
        let next = try await reopened.claimNext(chatID: "chat")
        XCTAssertNil(next.message)
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

    func testMiddleIntentEditAndCancellationPreserveFIFOReplyAndOrdinaryDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        for id in ["A", "B", "C"] {
            _ = try await store.enqueueText(
                chatID: "chat", threadID: "thread", senderID: 1, clientGeneratedID: id, text: id,
                enqueuedAt: Date(),
                clearedDraftRevision: Int64(["A", "B", "C"].firstIndex(of: id)! + 1),
                replyToMessage: preview(id: 103))
        }
        let draft = try await store.saveDraft(
            chatID: "chat", threadID: "thread", text: "ordinary", editRevision: 4,
            updatedAt: Date(), replyToMessage: preview(id: 104))
        let original = try XCTUnwrap(draft.outgoing.first { $0.clientGeneratedID == "B" })
        let edited = try await store.editOutgoing(
            chatID: "chat", threadID: "thread", itemID: "B",
            expectedRevision: original.editRevision, text: "  edited B\n", attachments: [])
        XCTAssertEqual(edited.draft, draft.draft)
        XCTAssertEqual(
            edited.outgoing.map(\.enqueueSequence), draft.outgoing.map(\.enqueueSequence))
        XCTAssertEqual(edited.outgoing[1].replyToMessage, original.replyToMessage)
        XCTAssertEqual(edited.outgoing[1].text, "edited B")
        XCTAssertEqual(edited.outgoing[1].editRevision, original.editRevision + 1)
        do {
            _ = try await store.cancelOutgoing(
                chatID: "chat", threadID: "thread", itemID: "B",
                expectedRevision: original.editRevision)
            XCTFail("An older editor cannot cancel newer intent")
        } catch LocalStorageError.staleDraft {}
        let cancelled = try await store.cancelOutgoing(
            chatID: "chat", threadID: "thread", itemID: "B",
            expectedRevision: edited.outgoing[1].editRevision)
        XCTAssertEqual(cancelled.outgoing.map(\.clientGeneratedID), ["A", "C"])
        XCTAssertEqual(cancelled.draft, draft.draft)
        XCTAssertGreaterThan(cancelled.revision, edited.revision)
        do {
            _ = try await store.editOutgoing(
                chatID: "chat", threadID: "thread", itemID: "B",
                expectedRevision: edited.outgoing[1].editRevision, text: "resurrect",
                attachments: [])
            XCTFail("A removed identity must remain unavailable")
        } catch LocalStorageError.staleDraft {}
    }

    func testConcurrentEditAndCancelRequireTheSameCapturedRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        _ = try await store.enqueueIndependentText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "original",
            enqueuedAt: Date())
        let edit = Task {
            try await store.editOutgoing(
                chatID: "chat", itemID: "A", expectedRevision: 0, text: "edited", attachments: [])
        }
        let cancel = Task {
            try await store.cancelOutgoing(chatID: "chat", itemID: "A", expectedRevision: 0)
        }
        var successes = 0
        for task in [edit, cancel] {
            do {
                _ = try await task.value
                successes += 1
            } catch LocalStorageError.staleDraft {}
        }
        XCTAssertEqual(successes, 1)
        let restored = try await store.restore()
        let item = restored.first?.outgoing.first
        XCTAssertTrue(item == nil || (item?.text == "edited" && item?.editRevision == 1))
    }

    func testConfirmationKeepsLeaseRowAndFinalizationCannotEraseNewerIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        _ = try await store.enqueueIndependentText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "original",
            enqueuedAt: Date())
        _ = try await store.claimNext(chatID: "chat")
        let created = try await store.acceptCreate(
            confirmation(itemID: "A", text: "original"), published: true)
        XCTAssertEqual(created.disposition, .completed)
        XCTAssertEqual(created.snapshot.outgoing.count, 1)
        let edited = try await store.editOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 0, text: "new intent", attachments: [])
        let staleFinalization = try await store.finalizeOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 0)
        XCTAssertEqual(staleFinalization, edited)
        let patch = try await store.claimPatch(chatID: "chat", itemID: "A")
        XCTAssertEqual(patch.patch?.attachmentIDs, [])
        let updated = try await store.acceptPatch(
            confirmation(itemID: "A", text: "new intent"), itemID: "A", revision: 1)
        XCTAssertEqual(updated.disposition, .completed)
        let duplicatePatch = try await store.acceptPatch(
            confirmation(itemID: "A", text: "obsolete duplicate"), itemID: "A", revision: 1)
        XCTAssertEqual(duplicatePatch.snapshot, updated.snapshot)
        let heldCreate = try await store.acceptCreate(
            confirmation(itemID: "A", text: "original"), published: true)
        XCTAssertEqual(heldCreate.snapshot.outgoing.first?.confirmedMessage?.message, "new intent")
        XCTAssertEqual(heldCreate.snapshot.outgoing.first?.acknowledgedRevision, 1)
        let completed = try await store.finalizeOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 1)
        XCTAssertTrue(completed.outgoing.isEmpty)
        let lateCreate = try await store.acceptCreate(
            confirmation(itemID: "A", text: "original"), published: true)
        XCTAssertTrue(lateCreate.snapshot.outgoing.isEmpty)
        XCTAssertEqual(lateCreate.disposition, .completed)
        let latePatch = try await store.acceptPatch(
            confirmation(itemID: "A", text: "obsolete duplicate"), itemID: "A", revision: 1)
        XCTAssertTrue(latePatch.snapshot.outgoing.isEmpty)
        XCTAssertEqual(latePatch.disposition, .completed)
    }

    func testClaimedPatchReplaysAcrossNewerIntentAndCancellationSuppressesItsPayload() async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let disabled = MessageMetadataInput(
            linkPreviews: [.init(url: "https://example.com", status: .disabled)])
        let enabled = MessageMetadataInput(
            linkPreviews: [.init(url: "https://example.com", status: .enabled)])
        _ = try await store!.enqueueIndependentText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "original",
            enqueuedAt: Date())
        _ = try await store!.claimNext(chatID: "chat")
        _ = try await store!.acceptCreate(
            confirmation(itemID: "A", text: "original"), published: true)
        _ = try await store!.editOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 0, text: "first edit", attachments: [],
            metadata: disabled)
        let first = try await store!.claimPatch(chatID: "chat", itemID: "A")
        XCTAssertEqual(first.patch?.metadata, disabled)
        _ = try await store!.editOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 1, text: "second edit", attachments: [],
            metadata: enabled)
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        XCTAssertEqual(restored.first?.outgoing.first?.claimedPatch, first.patch)
        XCTAssertEqual(restored.first?.outgoing.first?.metadata, enabled)
        let replay = try await store!.claimPatch(chatID: "chat", itemID: "A")
        XCTAssertEqual(replay.patch, first.patch)
        let older = try await store!.acceptPatch(
            confirmation(itemID: "A", text: "first edit"), itemID: "A", revision: 1)
        XCTAssertEqual(older.disposition, .retained)
        XCTAssertEqual(older.snapshot.outgoing.first?.text, "second edit")
        XCTAssertEqual(older.snapshot.outgoing.first?.acknowledgedRevision, 1)
        let latest = try await store!.claimPatch(chatID: "chat", itemID: "A")
        XCTAssertEqual(latest.patch?.metadata, enabled)
        let cancelled = try await store!.cancelOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 2)
        XCTAssertTrue(try XCTUnwrap(cancelled.outgoing.first).isCancelled)
        let failed = try await store!.failMutation(
            chatID: "chat", itemID: "A", patchRevision: nil, retryable: false)
        XCTAssertEqual(failed.outgoing.first?.state, .failed)
        let obsoletePatch = try await store!.acceptPatch(
            confirmation(itemID: "A", text: "second edit"), itemID: "A", revision: 2)
        XCTAssertEqual(obsoletePatch.disposition, .cancelled)
        XCTAssertEqual(
            obsoletePatch.snapshot.outgoing.first?.confirmedMessage?.message, "first edit")
        XCTAssertEqual(obsoletePatch.snapshot.outgoing.first?.state, .failed)
        XCTAssertFalse(try XCTUnwrap(obsoletePatch.snapshot.outgoing.first).mutationRetryable)
        let forbidden = try await store!.claimPatch(chatID: "chat", itemID: "A")
        XCTAssertNil(forbidden.patch)
        let deleted = try await store!.acceptDelete(chatID: "chat", itemID: "A")
        XCTAssertEqual(deleted.disposition, .cancelled)
        XCTAssertTrue(deleted.snapshot.outgoing.isEmpty)
    }

    func testMutationFailureRecoveryRetriesOnlyPersistedRetryableStages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        for id in ["transient", "permanent", "create"] {
            _ = try await store!.enqueueIndependentText(
                chatID: id, senderID: 1, clientGeneratedID: id, text: "original", enqueuedAt: Date()
            )
            _ = try await store!.claimNext(chatID: id)
            if id == "create" {
                _ = try await store!.fail(chatID: id, clientGeneratedID: id)
            } else {
                _ = try await store!.acceptCreate(
                    confirmation(itemID: id, text: "original", chatID: id), published: true)
                _ = try await store!.editOutgoing(
                    chatID: id, itemID: id, expectedRevision: 0, text: "edited", attachments: [])
                _ = try await store!.claimPatch(chatID: id, itemID: id)
                _ = try await store!.failMutation(
                    chatID: id, itemID: id, patchRevision: 1, retryable: id == "transient")
            }
        }
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        let items = Dictionary(uniqueKeysWithValues: restored.map { ($0.chatID, $0.outgoing[0]) })
        XCTAssertEqual(items["transient"]?.state, .queued)
        XCTAssertTrue(try XCTUnwrap(items["transient"]).mutationRetryable)
        XCTAssertEqual(items["permanent"]?.state, .failed)
        XCTAssertEqual(items["create"]?.state, .failed)
        let blocked = try await store!.claimPatch(chatID: "permanent", itemID: "permanent")
        XCTAssertNil(blocked.patch)
        _ = try await store!.retry(
            chatID: "permanent", clientGeneratedID: "permanent", scope: .message)
        let explicit = try await store!.claimPatch(chatID: "permanent", itemID: "permanent")
        XCTAssertEqual(explicit.patch?.text, "edited")
    }

    func testQueuedVideoEditsSupportLocalImportAndServerReorderingAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        _ = try await store.enqueueIndependentText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "original",
            enqueuedAt: Date())
        let original = try await store.claimNext(chatID: "chat")
        _ = try await store.acceptCreate(
            confirmation(itemID: "A", text: "original"), published: true)
        let videoFile = directory.appendingPathComponent("video.mov")
        try Data([1, 2, 3]).write(to: videoFile)
        let video = LocalOutgoingAttachment(
            id: "video", generation: UUID().uuidString, position: 0,
            sourcePath: videoFile.path, preparedPath: videoFile.path, previewPath: videoFile.path,
            fileName: "video.mov", mimeType: "video/quicktime", width: 10, height: 10, byteCount: 3,
            attachmentID: "uploaded-video")
        var image = try attachment(directory: directory, id: "image", position: 1)
        image.attachmentID = "uploaded-image"
        let imported = try await store.editOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 0, text: "media",
            attachments: [.local(video), .local(image)])
        XCTAssertEqual(imported.outgoing.first?.intentAttachments, [.local(video), .local(image)])
        XCTAssertEqual(imported.outgoing.first?.body, original.message?.body)
        let uploaded = try await store.claimPatch(chatID: "chat", itemID: "A")
        XCTAssertEqual(uploaded.patch?.attachmentIDs, ["uploaded-video", "uploaded-image"])
        let serverVideo = AttachmentResponse(
            id: "uploaded-video", url: "https://example.test/video.mov", kind: "video/quicktime",
            size: 3, fileName: "video.mov", width: 10, height: 10)
        let serverImage = AttachmentResponse(
            id: "uploaded-image", url: "https://example.test/image.png", kind: "image/png",
            size: 3, fileName: "image.png", width: 10, height: 10)
        _ = try await store.acceptPatch(
            confirmation(itemID: "A", text: "media", attachments: [serverVideo, serverImage]),
            itemID: "A", revision: 1)
        _ = try await store.editOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 1, text: "media",
            attachments: [.server(serverImage), .server(serverVideo)])
        let reordered = try await store.claimPatch(chatID: "chat", itemID: "A")
        XCTAssertEqual(reordered.patch?.attachmentIDs, ["uploaded-image", "uploaded-video"])
        _ = try await store.acceptPatch(
            confirmation(itemID: "A", text: "media", attachments: [serverImage, serverVideo]),
            itemID: "A", revision: 2)
        _ = try await store.editOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 2, text: "media",
            attachments: [.server(serverImage)])
        let removed = try await store.claimPatch(chatID: "chat", itemID: "A")
        XCTAssertEqual(removed.patch?.attachmentIDs, ["uploaded-image"])
        XCTAssertEqual(removed.snapshot.outgoing.first?.body, original.message?.body)
    }

    func testMixedIntentCheckpointsPreserveOrderFrozenCreateAndRelocatedOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let relocated = root.appendingPathComponent("relocated")
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: original)
        let begun = try await store!.beginComposition(
            chatID: "chat", threadID: "thread", senderID: 1)
        let item = try XCTUnwrap(begun.composingItem)
        let borrowed = try attachment(directory: original, id: "borrowed", position: 0)
        let attached = try await store!.setCompositionAttachments(
            chatID: "chat", threadID: "thread", itemID: item.clientGeneratedID,
            expectedRevision: item.editRevision, attachments: [borrowed], compressionEnabled: false)
        // The compression selection creates a new content generation. Complete the
        // durable slot's upload, not the pre-selection fixture's stale generation.
        var uploaded = try XCTUnwrap(attached.draft.attachments.first)
        uploaded.attachmentID = "uploaded-original"
        _ = try await store!.checkpointAttachment(
            chatID: "chat", threadID: "thread", itemID: item.clientGeneratedID, attachment: uploaded
        )
        let released = try await store!.enqueueText(
            chatID: "chat", threadID: "thread", senderID: 1, clientGeneratedID: "unused",
            text: "original", enqueuedAt: Date(),
            clearedDraftRevision: attached.draft.editRevision + 1)
        let pending = try XCTUnwrap(released.outgoing.first)
        let claim = try await store!.claimNext(chatID: "chat", threadID: "thread")
        let claimed = try XCTUnwrap(claim.message)
        let server = AttachmentResponse(
            id: "uploaded-original", url: "https://example.test/image", kind: "image",
            size: 3, fileName: "original.png", width: 10, height: 10)
        _ = try await store!.acceptCreate(
            confirmation(
                itemID: item.clientGeneratedID, text: "original", threadID: "thread",
                attachments: [server]), published: true)
        var added = try attachment(directory: original, id: "added", position: 1)
        let edited = try await store!.editOutgoing(
            chatID: "chat", threadID: "thread", itemID: item.clientGeneratedID,
            expectedRevision: pending.editRevision, text: "mixed",
            attachments: [.server(server), .local(added)])
        XCTAssertEqual(edited.outgoing.first?.body, claimed.body)
        added.preparedPath = added.sourcePath
        added.attachmentID = "uploaded-added"
        let checkpoint = try await store!.checkpointAttachment(
            chatID: "chat", threadID: "thread", itemID: item.clientGeneratedID, attachment: added)
        XCTAssertEqual(
            checkpoint.outgoing.first?.intentAttachments, [.server(server), .local(added)])
        XCTAssertEqual(checkpoint.outgoing.first?.body.attachmentIds, ["uploaded-original"])
        store = nil
        try FileManager.default.moveItem(at: original, to: relocated)
        store = try ChahuaLocalStore(directory: relocated)
        let restored = try await store!.restore()
        let selection = try XCTUnwrap(restored.first?.outgoing.first?.intentAttachments)
        guard case .local(let relocatedSlot) = selection[1] else {
            return XCTFail("The imported slot must retain its local ownership")
        }
        XCTAssertTrue(relocatedSlot.sourcePath.hasPrefix(relocated.path + "/"))
        let patch = try await store!.claimPatch(
            chatID: "chat", threadID: "thread", itemID: item.clientGeneratedID)
        XCTAssertEqual(patch.patch?.attachmentIDs, ["uploaded-original", "uploaded-added"])
        let removed = try await store!.editOutgoing(
            chatID: "chat", threadID: "thread", itemID: item.clientGeneratedID,
            expectedRevision: pending.editRevision + 1, text: "server only",
            attachments: [.server(server)])
        var late = relocatedSlot
        late.error = "obsolete upload"
        let ignored = try await store!.checkpointAttachment(
            chatID: "chat", threadID: "thread", itemID: item.clientGeneratedID, attachment: late)
        XCTAssertEqual(ignored, removed)
        let wrongThread = try await store!.claimPatch(
            chatID: "chat", itemID: item.clientGeneratedID)
        XCTAssertNil(wrongThread.patch)
        let other = try ChahuaLocalStore(directory: root.appendingPathComponent("other-account"))
        let isolated = try await other.restore()
        XCTAssertTrue(isolated.isEmpty)
    }

    func testVersionSevenMigrationFreezesClaimedRequestWithoutChangingItsIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let queued = try await store!.enqueueText(
            chatID: "chat", threadID: "thread", senderID: 1, clientGeneratedID: "legacy",
            text: "legacy text", enqueuedAt: Date(timeIntervalSince1970: 100),
            clearedDraftRevision: 5,
            replyToMessage: preview(id: 103))
        let claimed = try await store!.claimNext(chatID: "chat", threadID: "thread")
        store = nil
        try await removeVersionEightColumns(directory: directory)
        store = try ChahuaLocalStore(directory: directory)
        let beforeRestore = try await store!.claimNext(chatID: "chat", threadID: "thread")
        XCTAssertNil(beforeRestore.message)
        XCTAssertEqual(
            beforeRestore.snapshot.outgoing.first?.frozenCreate?.body, claimed.message?.body)
        let restored = try await store!.restore()
        let item = try XCTUnwrap(restored.first?.outgoing.first)
        XCTAssertEqual(item.clientGeneratedID, "legacy")
        XCTAssertEqual(item.body, claimed.message?.body)
        XCTAssertEqual(item.frozenCreate?.revision, 5)
        XCTAssertEqual(item.replyToMessage, queued.outgoing.first?.replyToMessage)
        XCTAssertEqual(item.enqueueSequence, queued.outgoing.first?.enqueueSequence)
        XCTAssertNil(item.intentAttachments)
        XCTAssertNil(item.confirmedMessage)
        XCTAssertEqual(item.acknowledgedRevision, -1)
        XCTAssertFalse(item.isPublished)
        XCTAssertFalse(item.isCancelled)
        XCTAssertFalse(item.mutationRetryable)
        let edited = try await store!.editOutgoing(
            chatID: "chat", threadID: "thread", itemID: "legacy", expectedRevision: 5,
            text: "new intent", attachments: [])
        XCTAssertEqual(edited.outgoing.first?.body, claimed.message?.body)
    }

    func testLegacyClaimWithUnresolvedAttachmentFailsRatherThanInventingARequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        let begun = try await store!.beginComposition(chatID: "chat", senderID: 1)
        let item = try XCTUnwrap(begun.composingItem)
        let slot = try attachment(directory: directory, id: "unresolved", position: 0)
        let attached = try await store!.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            attachments: [slot], compressionEnabled: true)
        _ = try await store!.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "unused", text: "",
            enqueuedAt: Date(), clearedDraftRevision: attached.draft.editRevision + 1)
        store = nil
        try await removeVersionEightColumns(directory: directory)
        do {
            let database = try DatabaseQueue(
                path: directory.appendingPathComponent("chat.sqlite").path)
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE outgoing_message SET dispatch_claimed = 1, state = 'sending'")
            }
        }
        store = try ChahuaLocalStore(directory: directory)
        do {
            _ = try await store!.restore()
            XCTFail("A claimed request with missing upload IDs must surface storage corruption")
        } catch LocalStorageError.corruptRecord {}
    }

    func testUnpublishedConfirmedAudioSurvivesFinalizationUntilActualPublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let file = directory.appendingPathComponent("voice.m4a")
        try Data([1, 2, 3]).write(to: file)
        var voice = LocalOutgoingAttachment(
            id: "voice", generation: "generation", position: 0, sourcePath: file.path,
            preparedPath: file.path, previewPath: file.path, fileName: "voice.m4a",
            mimeType: "audio/mp4", width: 0, height: 0, byteCount: 3)
        _ = try await store.enqueueVoice(
            chatID: "chat", senderID: 1, clientGeneratedID: "voice",
            attachment: voice, enqueuedAt: Date())
        voice.attachmentID = "uploaded-voice"
        _ = try await store.checkpointAttachment(chatID: "chat", itemID: "voice", attachment: voice)
        _ = try await store.claimNext(chatID: "chat")
        let audio = MessageResponse(
            id: MessageID(7), chatId: "chat", clientGeneratedId: "voice", messageType: .audio,
            sender: User(uid: 1, gender: 0, name: nil, avatarUrl: nil, userGroup: nil),
            createdAt: Date(timeIntervalSince1970: 1))
        let initial = try await store.acceptCreate(audio, published: false)
        XCTAssertEqual(initial.disposition, .retained)
        let premature = try await store.finalizeOutgoing(
            chatID: "chat", itemID: "voice", expectedRevision: 0)
        XCTAssertEqual(premature.outgoing.count, 1)
        let published = try await store.acceptCreate(audio, published: true)
        XCTAssertEqual(published.disposition, .completed)
        let finalized = try await store.finalizeOutgoing(
            chatID: "chat", itemID: "voice", expectedRevision: 0)
        XCTAssertTrue(finalized.outgoing.isEmpty)
    }

    func testCancellationTombstoneSkipsCreateFIFOAndRequiresKnownIdentityForDeletion() async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        for id in ["A", "B", "C"] {
            _ = try await store.enqueueIndependentText(
                chatID: "chat", senderID: 1, clientGeneratedID: id, text: id, enqueuedAt: Date())
        }
        _ = try await store.claimNext(chatID: "chat")
        let cancelled = try await store.cancelOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 0)
        XCTAssertTrue(try XCTUnwrap(cancelled.outgoing.first).isCancelled)
        do {
            _ = try await store.acceptDelete(chatID: "chat", itemID: "A")
            XCTFail("Unknown cancelled creates must remain durable tombstones")
        } catch LocalStorageError.staleDraft {}
        let next = try await store.claimNext(chatID: "chat")
        XCTAssertEqual(next.message?.clientGeneratedID, "B")
        let accepted = try await store.acceptCreate(
            confirmation(itemID: "A", text: "A"), published: true)
        XCTAssertEqual(accepted.disposition, .cancelled)
        let noPatch = try await store.claimPatch(chatID: "chat", itemID: "A")
        XCTAssertNil(noPatch.patch)
        let deleted = try await store.acceptDelete(chatID: "chat", itemID: "A")
        XCTAssertEqual(deleted.snapshot.outgoing.map(\.clientGeneratedID), ["B", "C"])
    }

    func testAuthoritativeDeletionRemovesUncancelledConfirmedEditorTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        _ = try await store.enqueueIndependentText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "original",
            enqueuedAt: Date())
        _ = try await store.claimNext(chatID: "chat")
        _ = try await store.acceptCreate(
            confirmation(itemID: "A", text: "original"), published: true)
        _ = try await store.editOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 0, text: "unsent edit", attachments: [])
        let deleted = try await store.acceptDelete(chatID: "chat", itemID: "A")
        XCTAssertEqual(deleted.disposition, .cancelled)
        XCTAssertTrue(deleted.snapshot.outgoing.isEmpty)
    }

    func testEditRejectsInvalidSelectionAndCrossAccountSourcesWithoutLosingPriorIntent()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("account")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let store = try ChahuaLocalStore(directory: directory)
        let queued = try await store.enqueueIndependentText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "original",
            enqueuedAt: Date())
        let external = try attachment(directory: other, id: "external", position: 0)
        let local = try attachment(directory: directory, id: "local", position: 0)
        let unknown = AttachmentResponse(
            id: "unowned", url: "https://example.test/image", kind: "image",
            size: 3, fileName: "image.png", width: 10, height: 10)
        let invalidSelections: [[LocalEditAttachment]] = [
            [.local(external)], [.local(local), .local(local)], [.server(unknown)],
        ]
        for selection in invalidSelections {
            do {
                _ = try await store.editOutgoing(
                    chatID: "chat", itemID: "A", expectedRevision: 0, text: "changed",
                    attachments: selection)
                XCTFail("Invalid attachment ownership or duplicate identity must be rejected")
            } catch LocalStorageError.invalidAttachments {}
        }
        do {
            _ = try await store.editOutgoing(
                chatID: "chat", itemID: "A", expectedRevision: 0, text: " \n ", attachments: [])
            XCTFail("An edit must retain text or media")
        } catch LocalStorageError.blankMessage {}
        let snapshots = try await store.restore()
        XCTAssertEqual(snapshots.first, queued)
        let mediaOnly = try await store.editOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 0, text: " \n ",
            attachments: [.local(local)])
        XCTAssertEqual(mediaOnly.outgoing.first?.text, "")
        XCTAssertEqual(mediaOnly.outgoing.first?.intentAttachments, [.local(local)])
        let unresolved = try await store.claimNext(chatID: "chat")
        XCTAssertNil(unresolved.message)
    }

    func testMismatchedConfirmationAndPatchRevisionNeverConsumeIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        _ = try await store.enqueueIndependentText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "original",
            enqueuedAt: Date())
        _ = try await store.claimNext(chatID: "chat")
        for invalid in [
            confirmation(itemID: "A", text: "original", senderID: 2),
            confirmation(itemID: "A", text: "original", threadID: "other-thread"),
            confirmation(itemID: "A", text: "original", chatID: "other-chat"),
        ] {
            do {
                _ = try await store.acceptCreate(invalid, published: true)
                XCTFail("A different sender or conversation cannot confirm this identity")
            } catch LocalStorageError.staleDraft {}
        }
        _ = try await store.acceptCreate(
            confirmation(itemID: "A", text: "original"), published: true)
        _ = try await store.editOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 0, text: "edited", attachments: [])
        let claimed = try await store.claimPatch(chatID: "chat", itemID: "A")
        do {
            _ = try await store.acceptPatch(
                confirmation(itemID: "A", text: "wrong"), itemID: "A", revision: 2)
            XCTFail("Only the exact claimed revision can advance acknowledgement")
        } catch LocalStorageError.staleDraft {}
        let staleFailure = try await store.failMutation(
            chatID: "chat", itemID: "A", patchRevision: 2, retryable: false)
        XCTAssertEqual(staleFailure, claimed.snapshot)
        let staleFinalization = try await store.finalizeOutgoing(
            chatID: "chat", itemID: "A", expectedRevision: 1)
        XCTAssertEqual(staleFinalization, claimed.snapshot)
    }

    func testLegacyClaimIsFrozenBeforeDirectEditOrCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for cancels in [false, true] {
            let directory = root.appendingPathComponent(cancels ? "cancel" : "edit")
            let store = try ChahuaLocalStore(directory: directory)
            _ = try await store.enqueueIndependentText(
                chatID: "chat", senderID: 1, clientGeneratedID: "legacy",
                text: "original request", enqueuedAt: Date())
            let claimed = try await store.claimNext(chatID: "chat")
            do {
                let database = try DatabaseQueue(
                    path: directory.appendingPathComponent("chat.sqlite").path)
                try await database.write { db in
                    try db.execute(sql: "UPDATE outgoing_message SET frozen_create = NULL")
                }
            }
            let changed: LocalConversationSnapshot
            if cancels {
                changed = try await store.cancelOutgoing(
                    chatID: "chat", itemID: "legacy", expectedRevision: 0)
                XCTAssertTrue(try XCTUnwrap(changed.outgoing.first).isCancelled)
            } else {
                changed = try await store.editOutgoing(
                    chatID: "chat", itemID: "legacy", expectedRevision: 0, text: "new intent",
                    attachments: [])
                XCTAssertEqual(changed.outgoing.first?.text, "new intent")
            }
            XCTAssertEqual(changed.outgoing.first?.body, claimed.message?.body)
            XCTAssertEqual(changed.outgoing.first?.frozenCreate?.revision, 0)
        }
    }

    func testEditAndCancelStorageFailureRollBackContentAndConversationRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let original = try await store.enqueueIndependentText(
            chatID: "chat", senderID: 1, clientGeneratedID: "A", text: "original",
            enqueuedAt: Date())
        do {
            let database = try DatabaseQueue(
                path: directory.appendingPathComponent("chat.sqlite").path)
            try await database.write { db in
                try db.execute(
                    sql: """
                        CREATE TRIGGER reject_intent_edit BEFORE UPDATE OF text ON outgoing_message
                        BEGIN SELECT RAISE(ABORT, 'held storage failure'); END;
                        CREATE TRIGGER reject_intent_cancel BEFORE DELETE ON outgoing_message
                        BEGIN SELECT RAISE(ABORT, 'held storage failure'); END;
                        """)
            }
        }
        do {
            _ = try await store.editOutgoing(
                chatID: "chat", itemID: "A", expectedRevision: 0, text: "new intent",
                attachments: [])
            XCTFail("A failed local commit cannot report a successful edit")
        } catch is DatabaseError {}
        do {
            _ = try await store.cancelOutgoing(chatID: "chat", itemID: "A", expectedRevision: 0)
            XCTFail("A failed local commit cannot hide the outgoing item")
        } catch is DatabaseError {}
        let restored = try await store.restore()
        XCTAssertEqual(restored.first, original)
    }

    func testFailedDeletionRestoresOnlyRetryableCancellationWithoutDispatchingCreate() async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ChahuaLocalStore? = try ChahuaLocalStore(directory: directory)
        for id in ["transient", "permanent"] {
            _ = try await store!.enqueueIndependentText(
                chatID: id, senderID: 1, clientGeneratedID: id, text: id, enqueuedAt: Date())
            _ = try await store!.claimNext(chatID: id)
            _ = try await store!.acceptCreate(
                confirmation(itemID: id, text: id, chatID: id), published: true)
            _ = try await store!.cancelOutgoing(chatID: id, itemID: id, expectedRevision: 0)
            _ = try await store!.failMutation(
                chatID: id, itemID: id, patchRevision: nil, retryable: id == "transient")
        }
        store = nil
        store = try ChahuaLocalStore(directory: directory)
        let restored = try await store!.restore()
        let items = Dictionary(uniqueKeysWithValues: restored.map { ($0.chatID, $0.outgoing[0]) })
        XCTAssertEqual(items["transient"]?.state, .queued)
        XCTAssertEqual(items["permanent"]?.state, .failed)
        XCTAssertTrue(items.values.allSatisfy(\.isCancelled))
        _ = try await store!.retry(
            chatID: "permanent", clientGeneratedID: "permanent", scope: .message)
        for id in ["transient", "permanent"] {
            let noCreate = try await store!.claimNext(chatID: id)
            XCTAssertNil(noCreate.message)
            let deleted = try await store!.acceptDelete(chatID: id, itemID: id)
            XCTAssertTrue(deleted.snapshot.outgoing.isEmpty)
        }
    }

    func testLegacyClaimedPatchDecodesWithoutMetadata() throws {
        let data = Data(#"{"text":"original","attachmentIDs":[],"revision":1}"#.utf8)
        let patch = try JSONDecoder().decode(LocalClaimedPatch.self, from: data)
        XCTAssertNil(patch.metadata)
        XCTAssertEqual(patch.revision, 1)
    }

    func testFileCaptionKeepsLinkIntentsOnAdjacentTextMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChahuaLocalStore(directory: directory)
        let initial = try await store.beginComposition(chatID: "chat", senderID: 1)
        var file = try attachment(directory: directory, id: "file", position: 0)
        file.preservesOriginal = true
        file.width = 0
        file.height = 0
        file.preparedPath = file.sourcePath
        let attached = try await store.setCompositionAttachments(
            chatID: "chat", itemID: try XCTUnwrap(initial.draft.itemID),
            expectedRevision: initial.draft.editRevision, attachments: [file],
            compressionEnabled: false)
        let metadata = MessageMetadataInput(
            linkPreviews: [.init(url: "https://example.com", status: .disabled)])
        let released = try await store.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "unused",
            text: "https://example.com", enqueuedAt: Date(),
            clearedDraftRevision: attached.draft.editRevision + 1, metadata: metadata)
        XCTAssertEqual(released.outgoing.map(\.messageType), [.file, .text])
        XCTAssertNil(released.outgoing.first?.metadata)
        XCTAssertEqual(released.outgoing.last?.body.metadata, metadata)
        let restored = try await store.restore()
        XCTAssertEqual(restored.first?.outgoing.last?.body.metadata, metadata)
    }

    private func removeVersionEightColumns(directory: URL) async throws {
        let database = try DatabaseQueue(path: directory.appendingPathComponent("chat.sqlite").path)
        try await database.write { db in
            for column in [
                "frozen_create", "intent_attachments", "confirmed_message", "is_published",
                "is_cancelled", "acknowledged_revision", "claimed_patch", "mutation_retryable",
            ] {
                try db.execute(sql: "ALTER TABLE outgoing_message DROP COLUMN \(column)")
            }
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = 'v8_outgoing_intents'")
        }
    }

    private func confirmation(
        itemID: String, text: String, chatID: String = "chat", threadID: String? = nil,
        id: UInt64 = 7, senderID: Int32 = 1, messageType: MessageType = .text,
        attachments: [AttachmentResponse] = []
    ) -> MessageResponse {
        MessageResponse(
            id: MessageID(id), chatId: chatID, clientGeneratedId: itemID, messageType: messageType,
            sender: User(uid: senderID, gender: 0, name: nil, avatarUrl: nil, userGroup: nil),
            createdAt: Date(timeIntervalSince1970: 1),
            hasAttachments: !attachments.isEmpty, attachments: attachments,
            message: text, replyRootId: threadID)
    }

    private func deliver(
        _ store: ChahuaLocalStore, chatID: String, threadID: String? = nil, itemID: String
    ) async throws -> LocalConversationSnapshot {
        let restored = try await store.restore()
        let item = try XCTUnwrap(
            restored.first {
                $0.conversationKey == ConversationKey(chatID: chatID, threadID: threadID)
            }?
            .outgoing.first { $0.clientGeneratedID == itemID })
        _ = try await store.acceptCreate(
            confirmation(
                itemID: itemID, text: item.text, chatID: chatID, threadID: threadID,
                messageType: item.messageType),
            published: true)
        return try await store.finalizeOutgoing(
            chatID: chatID, threadID: threadID, itemID: itemID, expectedRevision: item.editRevision)
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

    private func preview(id: UInt64) -> MessagePreview {
        MessagePreview(
            id: MessageID(id), clientGeneratedId: "client-\(id)",
            createdAt: Date(timeIntervalSince1970: 1),
            sender: User(uid: 2, gender: 0, name: "Ada", avatarUrl: nil, userGroup: nil),
            messageType: .text, attachments: [], mentions: [], isDeleted: false,
            message: "Reply to \(id)", sticker: nil
        )
    }
}
