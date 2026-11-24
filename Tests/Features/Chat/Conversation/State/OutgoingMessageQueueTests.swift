import ChahuaAPI
import Combine
import Foundation
import XCTest

@testable import chahua_apple

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

@MainActor
final class OutgoingMessageQueueTests: XCTestCase {
    /// Server IDs handed out by `response(_:)`, stable per client-generated ID.
    private var serverIDs: [String: UInt64] = [:]

    func testGroupWriteRefusalRetainsPayloadAndRequiresManualRetryAfterRestrictionLifts()
        async throws
    {
        let h = try await openHarness(foreground: false)
        var restricted = false
        h.queue.isWriteRestricted = { _ in restricted }
        h.queue.onWriteRejected = { error in
            if (error as? APIError)?.isGroupChatWriteRestricted == true { restricted = true }
        }
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "keep this message")
        await h.queue.setForegroundActive(true)
        try await eventually { await h.api.requests().count == 1 }
        let original = try await firstRequest(h.api)
        await h.api.finish(
            0,
            with: .failure(
                APIError.http(
                    status: 403, body: Data(#"{"reason":"groupChatWriteRestricted"}"#.utf8))))
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
        let failed = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        XCTAssertEqual(failed.failure?.reason, .groupChatWriteRestricted)
        XCTAssertEqual(failed.failure?.retry, .manual)
        XCTAssertEqual(failed.text, "keep this message")
        do {
            try await h.queue.retry(chatID: "chat", clientGeneratedID: failed.clientGeneratedID)
            XCTFail("Retry must not bypass the current restriction")
        } catch SpeakingWriteError.groupChatWriteRestricted {}
        restricted = false
        h.queue.writePermissionsDidChange()
        let beforeRetry = await h.api.requests()
        XCTAssertEqual(beforeRetry.count, 1)
        try await h.queue.retry(chatID: "chat", clientGeneratedID: failed.clientGeneratedID)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests[1].body, original.body)
        await h.api.finish(1, with: .success(try response(requests[1])))
        try await eventually { h.queue.pendingMessages(chatID: "chat").isEmpty }
    }

    func testStructuredConflictSettlesServerCopyAndUnblocksFIFO() async throws {
        let h = try await openHarness(foreground: false)
        var delivered: [MessageResponse] = []
        let observation = h.queue.events.sink {
            if case .delivered(_, let message, _) = $0 { delivered.append(message) }
        }
        defer { observation.cancel() }
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "local")
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "next")
        await h.queue.setForegroundActive(true)
        try await eventually { await h.api.requests().count == 1 }
        let first = try await firstRequest(h.api)
        let existing = try response(first).replacingMessageText("server")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let conflict = try JSONSerialization.data(withJSONObject: [
            "code": "clientGeneratedIdConflict",
            "existingMessage": try JSONSerialization.jsonObject(with: encoder.encode(existing)),
        ])
        await h.api.finish(0, with: .failure(APIError.http(status: 409, body: conflict)))
        try await eventually { await h.api.requests().count == 2 }
        XCTAssertEqual(delivered.map(\.message), ["server"])
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["next"])
        _ = await h.queue.acceptAcknowledgement(existing)
        XCTAssertEqual(delivered.map(\.id), [existing.id])
        let requests = await h.api.requests()
        await h.api.finish(1, with: .success(try response(requests[1])))
    }

    func testForwardRestoresDedicatedSingleAndMergedThreadRequestsWithoutConsumingDraft()
        async throws
    {
        let h = try await openHarness(foreground: false)
        let sources = try [4, 2, 1, 3].map {
            try TimelineTestFixtures.message(
                id: UInt64($0), chatID: "source", at: $0, text: "captured \($0)")
        }
        let reply = sources[0].replyPreview
        try await h.queue.saveDraft(
            chatID: "chat", threadID: "thread", text: "keep composing",
            editRevision: 1, updatedAt: Date(), replyToMessage: reply)
        let key = ConversationKey(chatID: "chat", threadID: "thread")
        let draft = try XCTUnwrap(h.queue.snapshots[key]?.draft)
        try await h.queue.enqueueForward(chatID: "chat", sources: [sources[0]])
        try await h.queue.enqueueForward(chatID: "chat", threadID: "thread", sources: sources)
        let single = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let merged = try XCTUnwrap(
            h.queue.pendingMessages(chatID: "chat", threadID: "thread").first)
        XCTAssertEqual(h.queue.snapshots[key]?.draft, draft)
        XCTAssertTrue(single.attachments.isEmpty)
        XCTAssertTrue(merged.attachments.isEmpty)
        await h.close()

        let reopened = try await openHarness(root: h.root, foreground: false)
        let restored = try XCTUnwrap(
            reopened.queue.pendingMessages(chatID: "chat", threadID: "thread").first)
        XCTAssertEqual(restored.forwardRequest, merged.forwardRequest)
        XCTAssertEqual(restored.clientGeneratedID, merged.clientGeneratedID)
        assertDraftContent(reopened.queue.snapshots[key]?.draft, draft)
        let pending = PendingOutgoingMessage(
            chatID: "chat", threadID: "thread", clientGeneratedID: restored.clientGeneratedID,
            body: CreateMessageBody(
                messageType: .forwarded, clientGeneratedId: restored.clientGeneratedID),
            enqueuedAt: restored.enqueuedAt, senderID: 1, phase: .queued(blockedBy: nil),
            forwardRequest: restored.forwardRequest)
        let optimistic = try XCTUnwrap(pending.optimisticMessage)
        XCTAssertEqual(optimistic.messageType, .forwarded)
        XCTAssertEqual(optimistic.forwardedPreview?.total, 4)
        XCTAssertEqual(
            optimistic.forwardedPreview?.messages.map(\.originalMessageId),
            sources.sorted { $0.id < $1.id }.prefix(3).map(\.id))
        XCTAssertNil(optimistic.forwardedFrom)
        await reopened.queue.setForegroundActive(true)
        try await eventually { await reopened.api.requests().count == 2 }
        let requests = await reopened.api.requests()
        let singleIndex = try XCTUnwrap(requests.firstIndex { $0.singleForward != nil })
        let mergedIndex = try XCTUnwrap(requests.firstIndex { $0.mergedForward != nil })
        XCTAssertEqual(requests[singleIndex].sourceMessageID, sources[0].id)
        XCTAssertEqual(requests[singleIndex].singleForward?.sourceChatId, "source")
        XCTAssertEqual(
            requests[singleIndex].singleForward?.clientGeneratedId, single.clientGeneratedID)
        XCTAssertNil(requests[singleIndex].singleForward?.threadId)
        XCTAssertNil(requests[singleIndex].mergedForward)
        XCTAssertEqual(requests[mergedIndex].mergedForward?.threadId, "thread")
        XCTAssertEqual(
            requests[mergedIndex].mergedForward?.messageIds, restored.forwardRequest?.messageIDs)
        XCTAssertEqual(
            requests[mergedIndex].mergedForward?.clientGeneratedId, merged.clientGeneratedID)
        XCTAssertNil(requests[mergedIndex].singleForward)
        await reopened.api.finish(singleIndex, with: .success(try response(requests[singleIndex])))
        await reopened.api.finish(mergedIndex, with: .success(try response(requests[mergedIndex])))
        try await eventually {
            reopened.queue.pendingMessages(chatID: "chat").isEmpty
                && reopened.queue.pendingMessages(chatID: "chat", threadID: "thread").isEmpty
        }
        assertDraftContent(reopened.queue.snapshots[key]?.draft, draft)
    }

    func testForwardRetryKeepsCapturedPayloadAndSocketSuccessBeatsHTTPUnauthorized() async throws {
        let h = try await openHarness(foreground: false)
        var source = try TimelineTestFixtures.message(
            id: 10, chatID: "source", at: 1, text: "original")
        let other = try TimelineTestFixtures.message(id: 11, chatID: "source", at: 2)
        try await h.queue.enqueueForward(
            chatID: "chat", threadID: "thread", sources: [other, source], allowPlaceholders: true)
        let captured = try XCTUnwrap(
            h.queue.pendingMessages(chatID: "chat", threadID: "thread").first)
        source = source.replacingMessageText("changed after enqueue")
        try await h.queue.enqueueForward(chatID: "chat", threadID: "thread", sources: [source])
        await h.queue.setForegroundActive(true)
        try await eventually { await h.api.requests().count == 1 }
        let initial = try await firstRequest(h.api)
        await h.api.finish(0, with: .failure(QueueTestError.rejected))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat", threadID: "thread").map(\.state) == [
                .failed, .pending,
            ]
        }
        try await h.queue.retry(
            chatID: "chat", threadID: "thread", clientGeneratedID: captured.clientGeneratedID)
        try await eventually { await h.api.requests().count == 2 }
        let retried = await h.api.requests()
        XCTAssertEqual(retried[1].mergedForward, initial.mergedForward)
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat", threadID: "thread").first?.forwardRequest,
            captured.forwardRequest)
        XCTAssertEqual(captured.forwardRequest?.sources.first?.message, "original")
        let accepted = await h.queue.acceptAcknowledgement(try response(retried[1]))
        XCTAssertEqual(accepted, .consumed)
        await h.api.finish(1, with: .failure(APIError.invalidToken))
        // The ordered successor starts only after the obsolete HTTP failure is consumed.
        try await eventually { await h.api.requests().count == 3 }
        let finalRequests = await h.api.requests()
        XCTAssertNotNil(finalRequests[2].singleForward)
        XCTAssertNil(h.invalidTokenStates)
        await h.api.finish(2, with: .success(try response(finalRequests[2])))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat", threadID: "thread").isEmpty
        }
    }

    func testAcknowledgedAudioConsentIsCapturedAndPublicationCannotBeUndoneByLateHTTP() async throws
    {
        for publicationFirst in [false, true] {
            let h = try await openHarness(foreground: false)
            let store = try await h.openStore(uid: 1)
            let file = store.directory.appendingPathComponent("voice.m4a")
            try Data([1, 2, 3]).write(to: file)
            var attachment = LocalOutgoingAttachment(
                id: "voice", generation: UUID().uuidString, position: 0,
                sourcePath: file.path, preparedPath: file.path, previewPath: file.path,
                fileName: "voice.m4a", mimeType: "audio/mp4", width: 0, height: 0,
                byteCount: 3)
            _ = try await store.enqueueVoice(
                chatID: "source", clientGeneratedID: "voice-send",
                attachment: attachment, enqueuedAt: Date())
            attachment.attachmentID = "uploaded-voice"
            _ = try await store.checkpointAttachment(
                key: .init(chatID: "source"), itemID: "voice-send", attachment: attachment)
            await h.close()
            let sending = try await openHarness(root: h.root)
            var receiptPublication: [Bool] = []
            let observation = sending.queue.events.sink {
                if case .delivered(_, let message, let published) = $0,
                    message.clientGeneratedId == "voice-send"
                {
                    receiptPublication.append(published)
                }
            }
            defer { observation.cancel() }
            try await eventually { await sending.api.requests().count == 1 }
            try await sending.queue.enqueueIndependentText(chatID: "source", text: "after voice")
            let audio = try TimelineTestFixtures.message(
                id: 501, chatID: "source", at: 1, type: .audio, clientGeneratedID: "voice-send",
                fields: [
                    "hasAttachments": true,
                    "attachments": [
                        [
                            "id": "uploaded-voice", "url": "https://example.test/voice.m4a",
                            "kind": "audio/mp4", "size": 3, "fileName": "voice.m4a",
                        ]
                    ],
                ])
            if publicationFirst {
                let accepted = await sending.queue.acceptAcknowledgement(audio)
                XCTAssertEqual(accepted, .consumed)
            }
            await sending.api.finish(0, with: .success(audio))
            try await eventually { await sending.api.requests().count == 2 }
            let successor = await sending.api.requests()[1]
            XCTAssertEqual(successor.body.message, "after voice")
            XCTAssertEqual(receiptPublication, [publicationFirst])
            let historyStore = try await sending.openStore(uid: 1)
            let history = try await historyStore.cachedHistory(.init(chatID: "source"))
            XCTAssertEqual(history.messages.map(\.id), publicationFirst ? [audio.id] : [])
            if publicationFirst {
                XCTAssertTrue(sending.queue.acknowledgedPendingAudioMessages.isEmpty)
                XCTAssertNil(sending.queue.forwardPlaceholderReason(for: audio, merging: false))
            } else {
                XCTAssertEqual(sending.queue.acknowledgedPendingAudioMessages, [audio])
                XCTAssertEqual(
                    sending.queue.forwardPlaceholderReason(for: audio, merging: false),
                    "pendingAudio")
                await sending.queue.setForegroundActive(false)
                try await sending.queue.enqueueForward(
                    chatID: "chat", sources: [audio], allowPlaceholders: true)
                let pending = try XCTUnwrap(sending.queue.pendingMessages(chatID: "chat").first)
                let snapshot = try XCTUnwrap(pending.forwardRequest?.sources.first)
                XCTAssertEqual(snapshot.id, audio.id)
                XCTAssertEqual(snapshot.messageType, .placeholder)
                XCTAssertEqual(snapshot.message, "pendingAudio")
                XCTAssertTrue(snapshot.attachments.isEmpty)
                XCTAssertNil(snapshot.sticker)
                _ = await sending.queue.acceptAcknowledgement(audio)
                XCTAssertTrue(sending.queue.acknowledgedPendingAudioMessages.isEmpty)
                XCTAssertEqual(
                    sending.queue.pendingMessages(chatID: "chat").first?.forwardRequest,
                    pending.forwardRequest)
                await sending.queue.setForegroundActive(true)
                try await eventually { await sending.api.requests().count == 3 }
                let forward = await sending.api.requests()[2]
                XCTAssertEqual(forward.singleForward?.allowPlaceholders, true)
                XCTAssertEqual(forward.sourceMessageID, audio.id)
                await sending.api.finish(2, with: .success(try response(forward)))
                try await eventually { sending.queue.pendingMessages(chatID: "chat").isEmpty }
            }
            await sending.queue.activate(uid: 2)
            XCTAssertTrue(sending.queue.acknowledgedPendingAudioMessages.isEmpty)
            await sending.close()
        }
    }

    func testStickerSnapshotsAndFailedThreadSendSurviveRestartWithoutConsumingDrafts() async throws
    {
        let h = try await openHarness(foreground: false)
        let sticker = MessageStickerResponse(
            id: "sticker", emoji: "wave", createdAt: Date(timeIntervalSince1970: 1),
            isFavorited: true,
            media: MessageStickerMediaResponse(
                id: "media", url: "https://example.test/sticker.webp",
                contentType: "image/webp", size: 123, width: 200, height: 150),
            name: "Wave", description: "A wave")
        let reply = try TimelineTestFixtures.message(id: 100, at: 1).replyPreview
        try await h.queue.saveDraft(
            chatID: "chat", threadID: "thread", text: "unfinished",
            editRevision: 1, updatedAt: Date(), replyToMessage: reply)
        let draft = h.queue.snapshots[ConversationKey(chatID: "chat", threadID: "thread")]?.draft
        try await h.queue.enqueueSticker(chatID: "chat", sticker: sticker)
        try await h.queue.enqueueSticker(
            chatID: "chat", threadID: "thread", sticker: sticker, replyToMessage: reply)
        let parent = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let thread = try XCTUnwrap(
            h.queue.pendingMessages(chatID: "chat", threadID: "thread").first)
        XCTAssertEqual(h.queue.snapshots[thread.conversationKey]?.draft, draft)
        await h.close()

        let reopened = try await openHarness(root: h.root, foreground: false)
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "chat").first?.sticker, sticker)
        XCTAssertEqual(
            reopened.queue.pendingMessages(chatID: "chat", threadID: "thread").first?.sticker,
            sticker)
        assertDraftContent(reopened.queue.snapshots[thread.conversationKey]?.draft, draft)
        await reopened.queue.setForegroundActive(true)
        try await eventually { await reopened.api.requests().count == 2 }
        let requests = await reopened.api.requests()
        let parentIndex = try XCTUnwrap(requests.firstIndex { $0.threadID == nil })
        let threadIndex = try XCTUnwrap(requests.firstIndex { $0.threadID == "thread" })
        XCTAssertEqual(
            requests[parentIndex].body,
            CreateMessageBody(
                messageType: .sticker, clientGeneratedId: parent.clientGeneratedID,
                stickerId: sticker.id))
        XCTAssertEqual(
            requests[threadIndex].body,
            CreateMessageBody(
                messageType: .sticker, clientGeneratedId: thread.clientGeneratedID,
                replyToId: reply.id, stickerId: sticker.id))
        await reopened.api.finish(parentIndex, with: .success(try response(requests[parentIndex])))
        await reopened.api.finish(threadIndex, with: .failure(QueueTestError.rejected))
        try await eventually {
            reopened.queue.pendingMessages(chatID: "chat").isEmpty
                && reopened.queue.pendingMessages(chatID: "chat", threadID: "thread").first?.state
                    == .failed
        }
        await reopened.close()

        let retried = try await openHarness(root: h.root)
        let restored = try XCTUnwrap(
            retried.queue.pendingMessages(chatID: "chat", threadID: "thread").first)
        XCTAssertEqual(restored.state, .failed)
        XCTAssertEqual(restored.sticker, sticker)
        XCTAssertEqual(restored.replyToMessage, reply)
        try await retried.queue.retry(
            chatID: "chat", threadID: "thread",
            clientGeneratedID: thread.clientGeneratedID)
        try await eventually { await retried.api.requests().count == 1 }
        let request = try await firstRequest(retried.api)
        XCTAssertEqual(request.threadID, "thread")
        XCTAssertEqual(request.body, requests[threadIndex].body)
        await retried.api.finish(0, with: .success(try response(request)))
        try await eventually {
            retried.queue.pendingMessages(chatID: "chat", threadID: "thread").isEmpty
        }
        assertDraftContent(retried.queue.snapshots[thread.conversationKey]?.draft, draft)
    }

    func testStickerSubmissionPreservesDraftReplyAndTextAfterRestart() async throws {
        let h = try await openHarness(foreground: false)
        let drafts = ChatDraftStore(outgoingQueue: h.queue)
        let observation = h.queue.events.sink { event in
            if case .snapshot(let snapshot) = event { drafts.install(snapshot) }
        }
        let sticker = MessageStickerResponse(
            id: "sticker", emoji: "wave", createdAt: Date(timeIntervalSince1970: 1),
            isFavorited: false,
            media: MessageStickerMediaResponse(
                id: "media", url: "https://example.test/sticker.webp",
                contentType: "image/webp", size: 123, width: 200, height: 150),
            name: nil, description: nil)
        let reply = try TimelineTestFixtures.message(id: 100, at: 1).replyPreview
        drafts.setDraftText("keep typing", chatID: "chat", threadID: "thread")
        drafts.setDraftReply(reply, chatID: "chat", threadID: "thread")
        h.faults.failures = [.saveDraft]
        await drafts.flushDraft(chatID: "chat", threadID: "thread")
        XCTAssertTrue(drafts.draftSaveFailed)

        let submitted = try await drafts.submitSticker(sticker, chatID: "chat", threadID: "thread")
        XCTAssertTrue(submitted)
        XCTAssertEqual(drafts.draftText(chatID: "chat", threadID: "thread"), "keep typing")
        XCTAssertEqual(drafts.draftReply(chatID: "chat", threadID: "thread"), reply)
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat", threadID: "thread").first?.replyToMessage, reply
        )
        h.faults.failures = []
        await drafts.flushAll()
        observation.cancel()
        drafts.reset()
        await h.close()

        let reopened = try await openHarness(root: h.root, foreground: false)
        let snapshot = try XCTUnwrap(
            reopened.queue.snapshots[ConversationKey(chatID: "chat", threadID: "thread")])
        XCTAssertEqual(snapshot.draft.text, "keep typing")
        XCTAssertEqual(snapshot.draft.replyToMessage, reply)
        XCTAssertEqual(snapshot.outgoing.first?.sticker, sticker)
    }

    func testThreadSendRetryAndAcknowledgementsUseOnlyTheirConversation() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(
            chatID: "chat", threadID: "one", text: "reply", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        let first = try await firstRequest(h.api)
        XCTAssertEqual(first.chatID, "chat")
        XCTAssertEqual(first.threadID, "one")
        await h.api.finish(0, with: .failure(QueueTestError.rejected))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat", threadID: "one").first?.state == .failed
        }
        try await h.queue.enqueueText(chatID: "chat", text: "parent", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 2 }
        try await h.queue.enqueueText(
            chatID: "chat", threadID: "two", text: "other reply", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 3 }
        let requests = await h.api.requests()
        XCTAssertNil(requests[1].threadID)
        XCTAssertEqual(requests[2].threadID, "two")
        let wrongRoot = try TimelineTestFixtures.message(
            id: 1, at: 1, clientGeneratedID: first.body.clientGeneratedId,
            fields: ["replyRootId": "two"])
        let acceptedWrongRoot = await h.queue.acceptAcknowledgement(wrongRoot)
        XCTAssertEqual(acceptedWrongRoot, .unrelated)
        let wrongParent = try TimelineTestFixtures.message(
            id: 2, at: 1, clientGeneratedID: first.body.clientGeneratedId)
        let acceptedWrongParent = await h.queue.acceptAcknowledgement(wrongParent)
        XCTAssertEqual(acceptedWrongParent, .unrelated)
        try await h.queue.retry(
            chatID: "chat", threadID: "one", clientGeneratedID: first.body.clientGeneratedId)
        try await eventually { await h.api.requests().count == 4 }
        let retried = await h.api.requests()
        XCTAssertEqual(retried[3].threadID, "one")
        XCTAssertEqual(retried[3].body.clientGeneratedId, first.body.clientGeneratedId)
        XCTAssertEqual(retried[3].body.message, "reply")
        let accepted = await h.queue.acceptAcknowledgement(try response(retried[3]))
        XCTAssertEqual(accepted, .consumed)
        await h.api.finish(3, with: .failure(QueueTestError.rejected))
        await h.api.finish(1, with: .success(try response(requests[1])))
        await h.api.finish(2, with: .success(try response(requests[2])))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").isEmpty
                && h.queue.pendingMessages(chatID: "chat", threadID: "one").isEmpty
                && h.queue.pendingMessages(chatID: "chat", threadID: "two").isEmpty
                && h.queue.snapshots.values.allSatisfy { $0.outgoing.isEmpty }
        }
        await h.close()
        let store = try await h.openStore(uid: 1)
        let restored = try await store.restore()
        XCTAssertTrue(restored.flatMap(\.outgoing).isEmpty)
    }

    func testDraftCompositionSubmissionAndRestartAreThreadScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await openHarness(root: root, foreground: false)
        let drafts = ChatDraftStore(outgoingQueue: h.queue)
        let observation = h.queue.events.sink { event in
            if case .snapshot(let snapshot) = event { drafts.install(snapshot) }
        }
        let choices = [LinkPreviewInput(url: "https://example.com", status: .disabled)]
        drafts.setDraftLinkPreviews(choices, chatID: "chat")
        drafts.setDraftLinkPreviews(choices, chatID: "chat", threadID: "two")
        drafts.setDraftText("parent draft", chatID: "chat")
        drafts.setDraftComposing(true, chatID: "chat", threadID: "one")
        drafts.setDraftText("composing draft", chatID: "chat", threadID: "one")
        drafts.setDraftText("thread send", chatID: "chat", threadID: "two")
        let blocked = await drafts.submitDraft(chatID: "chat", threadID: "one")
        XCTAssertFalse(blocked)
        let submitted = await drafts.submitDraft(chatID: "chat", threadID: "two")
        XCTAssertTrue(submitted)
        XCTAssertEqual(drafts.draftText(chatID: "chat"), "parent draft")
        XCTAssertEqual(drafts.draftText(chatID: "chat", threadID: "one"), "composing draft")
        XCTAssertEqual(drafts.draftText(chatID: "chat", threadID: "two"), "")
        XCTAssertEqual(drafts.draftLinkPreviews(chatID: "chat"), choices)
        XCTAssertEqual(drafts.draftLinkPreviews(chatID: "chat", threadID: "two"), [])
        XCTAssertNotNil(drafts.draftUpdatedAt[ConversationKey(chatID: "chat", threadID: "one")])
        XCTAssertNil(drafts.draftUpdatedAt[ConversationKey(chatID: "chat", threadID: "two")])
        drafts.setDraftComposing(false, chatID: "chat", threadID: "one")
        await drafts.flushAll()
        observation.cancel()
        drafts.reset()
        await h.close()

        let reopened = try await openHarness(root: root, foreground: false)
        let restoredDrafts = ChatDraftStore(outgoingQueue: reopened.queue)
        for snapshot in reopened.queue.snapshots.values { restoredDrafts.install(snapshot) }
        XCTAssertEqual(restoredDrafts.draftText(chatID: "chat"), "parent draft")
        XCTAssertEqual(restoredDrafts.draftText(chatID: "chat", threadID: "one"), "composing draft")
        XCTAssertEqual(restoredDrafts.draftText(chatID: "chat", threadID: "two"), "")
        XCTAssertEqual(restoredDrafts.draftLinkPreviews(chatID: "chat"), choices)
        XCTAssertEqual(restoredDrafts.draftLinkPreviews(chatID: "chat", threadID: "one"), [])
        XCTAssertEqual(restoredDrafts.draftLinkPreviews(chatID: "chat", threadID: "two"), [])
        XCTAssertTrue(reopened.queue.pendingMessages(chatID: "chat").isEmpty)
        XCTAssertTrue(reopened.queue.pendingMessages(chatID: "chat", threadID: "one").isEmpty)
        XCTAssertEqual(
            reopened.queue.pendingMessages(chatID: "chat", threadID: "two").map(\.text),
            ["thread send"])
        await reopened.queue.setForegroundActive(true)
        try await eventually { await reopened.api.requests().count == 1 }
        let request = try await firstRequest(reopened.api)
        XCTAssertEqual(request.body.metadata?.linkPreviews, choices)
        XCTAssertEqual(request.chatID, "chat")
        XCTAssertEqual(request.threadID, "two")
        await reopened.api.finish(0, with: .success(try response(request)))
        try await eventually {
            reopened.queue.pendingMessages(chatID: "chat", threadID: "two").isEmpty
        }
        await reopened.close()
    }

    func testFailureLeavesSuccessorsQueuedWithoutBlockingAnotherChat() async throws {
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
        await h.api.finish(0, with: .failure(QueueTestError.rejected))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .pending, .pending]
        }
        XCTAssertTrue(transitions.contains([.failed, .pending, .pending]))
        XCTAssertFalse(transitions.contains([.failed, .failed, .failed]))
        try await h.queue.enqueueText(chatID: "other", text: "independent", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.chatID), ["chat", "other"])
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat").map(\.clientGeneratedID),
            rows.map(\.clientGeneratedID))
        observation.cancel()
        await h.close()
    }

    func testRetrySuccessorCannotBypassFailedHeadOrChangeFIFOIdentity() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.enqueueText(chatID: "chat", text: "D", clearedDraftRevision: 4)
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID)
        let pausedRequests = await h.api.requests()
        XCTAssertEqual(pausedRequests.map(\.body.message), ["A"])
        let pending = h.queue.pendingMessages(chatID: "chat")
        XCTAssertEqual(pending.map(\.text), ["A", "B", "C", "D"])
        XCTAssertEqual(pending.map(\.state), [.failed, .pending, .pending, .pending])
        XCTAssertEqual(
            Array(pending.prefix(3)).map(\.clientGeneratedID), rows.map(\.clientGeneratedID))
        try await h.queue.retry(
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID)
        try await eventually { await h.api.requests().count == 2 }
        var requests = await h.api.requests()
        XCTAssertEqual(requests[1].body, requests[0].body)
        await h.api.finish(1, with: .success(try response(requests[1])))
        try await eventually { await h.api.requests().count == 3 }
        requests = await h.api.requests()
        XCTAssertEqual(requests[2].body.clientGeneratedId, rows[1].clientGeneratedID)
        XCTAssertEqual(requests[2].body.message, "B")
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["B", "C", "D"])
        await h.close()
    }

    func testRetryHeadDrainsFIFOAndRepeatedTapsDoNotOverlap() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.retry(
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID)
        try await eventually { await h.api.requests().count == 2 }
        for _ in 0..<3 {
            try await h.queue.retry(
                chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID)
        }
        var requests = await h.api.requests()
        XCTAssertEqual(requests.count, 2)
        for index in 1...3 {
            XCTAssertEqual(
                requests[index].body.clientGeneratedId, rows[index - 1].clientGeneratedID)
            await h.api.finish(index, with: .success(try response(requests[index])))
            if index < 3 {
                try await eventually { await h.api.requests().count == index + 2 }
                requests = await h.api.requests()
            }
        }
        try await eventually { h.queue.pendingMessages(chatID: "chat").isEmpty }
        XCTAssertEqual(requests.map(\.body.message), ["A", "A", "B", "C"])
        let concurrency = await h.api.maximumConcurrency(chatID: "chat")
        XCTAssertEqual(concurrency, 1)
        await h.close()
    }

    func testRetryFailureDoesNotAttemptSuccessorsAndReusesOriginalBody() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.retry(
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID)
        try await eventually { await h.api.requests().count == 2 }
        await h.api.finish(1, with: .failure(QueueTestError.rejected))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .pending, .pending]
        }
        let requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.body.message), ["A", "A"])
        try await h.queue.retry(
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID)
        try await eventually { await h.api.requests().count == 3 }
        let repeated = await h.api.requests()
        XCTAssertEqual(repeated[0].body, repeated[1].body)
        XCTAssertEqual(repeated[1].body, repeated[2].body)
        await h.close()
    }

    func testEditingMiddleQueuedItemLeavesOrdinaryDraftAndFIFOIntact() async throws {
        let h = try await openHarness()
        let rows = try await enqueueABC(h)
        let reply = try TimelineTestFixtures.message(id: 90, at: 0).replyPreview
        try await h.queue.saveDraft(
            chatID: "chat", text: "ordinary draft", editRevision: 10, updatedAt: Date(),
            replyToMessage: reply)
        let session = try h.queue.beginPendingEdit(pendingProjection(rows[1]))
        try await h.queue.submitPendingEdit(session, text: "edited B", metadata: nil)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["A", "edited B", "C"])
        XCTAssertEqual(
            h.queue.snapshots[ConversationKey(chatID: "chat")]?.draft.text, "ordinary draft")
        XCTAssertEqual(
            h.queue.snapshots[ConversationKey(chatID: "chat")]?.draft.replyToMessage, reply)
        let first = try await firstRequest(h.api)
        await h.api.finish(0, with: .success(try response(first)))
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests[1].body.clientGeneratedId, rows[1].clientGeneratedID)
        XCTAssertEqual(requests[1].body.message, "edited B")
        await h.api.finish(1, with: .success(try response(requests[1])))
        try await eventually { await h.api.requests().count == 3 }
        let finalRequests = await h.api.requests()
        XCTAssertEqual(finalRequests[2].body.clientGeneratedId, rows[2].clientGeneratedID)
    }

    func testSocketFirstAcknowledgementAdvancesFIFOAndIgnoresLateFailure() async throws {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        let first = try await firstRequest(h.api)
        let message = try response(first)
        let handled = await h.queue.acceptAcknowledgement(message)
        XCTAssertEqual(handled, .consumed)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["B", "C"])
        try await eventually { await h.api.requests().count == 2 }
        let duplicate = await h.queue.acceptAcknowledgement(message)
        XCTAssertEqual(duplicate, .unrelated)
        await h.api.finish(0, with: .failure(QueueTestError.rejected))
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.sending, .pending])
        await h.close()
        let reopened = try await h.openStore(uid: 1)
        let restored = try await reopened.restore()
        XCTAssertFalse(
            restored.flatMap(\.outgoing).contains {
                $0.clientGeneratedID == message.clientGeneratedId
            })
    }

    func testStreamReceiptsSettleOnceWithoutCachingHistory() async throws {
        for deleted in [false, true] {
            let h = try await openHarness()
            let key = ConversationKey(chatID: "chat")
            try await h.queue.enqueueText(chatID: key.chatID, text: "A", clearedDraftRevision: 1)
            try await eventually { await h.api.requests().count == 1 }
            let request = try await firstRequest(h.api)
            let message = try response(request)
            var delivered: [MessageResponse] = []
            let observation = h.queue.events.sink {
                if case .delivered(_, let message, true) = $0 { delivered.append(message) }
            }
            defer { observation.cancel() }

            let handled: IncomingOutgoingDisposition
            if deleted {
                handled = await h.queue.acceptDeletion(message, cacheHistory: false)
            } else {
                handled = await h.queue.acceptAcknowledgement(message, cacheHistory: false)
            }
            XCTAssertEqual(handled, .consumed)
            await h.api.finish(0, with: .failure(QueueTestError.rejected))
            XCTAssertEqual(delivered, [deleted ? message.redactedForDeletion() : message])
            XCTAssertTrue(h.queue.pendingMessages(chatID: key.chatID).isEmpty)

            await h.close()
            let reopened = try await h.openStore(uid: 1)
            let restored = try await reopened.restore()
            XCTAssertTrue(restored.flatMap(\.outgoing).isEmpty)
            let history = try await reopened.cachedHistory(key)
            XCTAssertTrue(history.messages.isEmpty)

            // A deletion receipt must also leave the tombstone to ordered history persistence.
            let epoch = try await reopened.cacheEpoch()
            try await reopened.cacheChange(.create(message, key, adjoining: nil), epoch: epoch)
            let persisted = try await reopened.cachedHistory(key)
            XCTAssertEqual(persisted.messages, [message])
        }
    }

    func testHTTPFirstIsDurablyDeletedAndRejectsUnrelatedAcknowledgements() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        for invalid in [
            try TimelineTestFixtures.message(
                id: 1, chatID: "other", at: 1,
                clientGeneratedID: request.body.clientGeneratedId),
            try TimelineTestFixtures.message(
                id: 2, senderID: 2, at: 1,
                clientGeneratedID: request.body.clientGeneratedId),
            try TimelineTestFixtures.message(id: 3, at: 1, clientGeneratedID: ""),
        ] {
            let handled = await h.queue.acceptAcknowledgement(invalid)
            XCTAssertEqual(handled, .unrelated)
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

    func testHistoryForNeverClaimedIDDoesNotRemoveLocalIntent() async throws {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        let pending = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let message = try TimelineTestFixtures.message(
            id: 1, at: 1, clientGeneratedID: pending.clientGeneratedID)
        let handled = await h.queue.acceptAcknowledgement(message)
        XCTAssertEqual(handled, .unrelated)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat"), [pending])
        let requests = await h.api.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testOneBackgroundGrantDrainsFIFOAcrossConversations() async throws {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        try await h.queue.enqueueIndependentText(chatID: "other", text: "Independent")
        try await eventually { await h.api.requests().count == 2 }
        h.queue.requestForegroundActive(false)
        XCTAssertEqual(h.background.attempts, 1)
        let initial = await h.api.requests()
        XCTAssertEqual(initial.map(\.body.message), ["A", "Independent"])
        await h.api.finish(0, with: .success(try response(initial[0])))
        try await eventually { await h.api.requests().count == 3 }
        let second = await h.api.requests()[2]
        XCTAssertEqual(second.body.message, "B")
        await h.api.finish(2, with: .success(try response(second)))
        try await eventually { await h.api.requests().count == 4 }
        let third = await h.api.requests()[3]
        XCTAssertEqual(third.body.message, "C")
        await h.api.finish(3, with: .success(try response(third)))
        try await eventually { h.queue.pendingMessages(chatID: "chat").isEmpty }
        XCTAssertEqual(h.background.ended, 0)
        await h.api.finish(1, with: .success(try response(initial[1])))
        try await eventually { h.background.ended == 1 }
        XCTAssertNil(h.queue.automaticBackgroundWakeDate)
        XCTAssertEqual(h.background.attempts, 1)
    }

    func testBackgroundExpirationReleasesUnhandedClaimAndRetriesAmbiguousID() async throws {
        let h = try await openHarness()
        let authorization = HeldWriteAuthorization()
        defer { authorization.finish() }
        h.queue.authorizeWrite = { chat, _ in
            if chat == "preflight" { await authorization.wait() }
        }
        try await h.queue.enqueueIndependentText(chatID: "preflight", text: "Never handed off")
        try await h.queue.enqueueIndependentText(chatID: "create", text: "Already handed off")
        try await h.queue.enqueueIndependentText(chatID: "create", text: "Successor")
        try await eventually {
            guard authorization.isWaiting else { return false }
            return await h.api.requests().count == 1
        }
        let original = try await firstRequest(h.api)
        let unhandedID = try XCTUnwrap(
            h.queue.pendingMessages(chatID: "preflight").first?.clientGeneratedID)
        h.queue.requestForegroundActive(false)
        let expire = try XCTUnwrap(h.background.expirations.first)
        expire()
        expire()
        try await eventually {
            h.queue.pendingMessages(chatID: "preflight").first?.state == .pending
                && h.queue.pendingMessages(chatID: "create").first?.failure?.reason
                    == .unknownOutcome
        }
        XCTAssertEqual(h.background.ended, 1)
        h.queue.authorizeWrite = nil
        authorization.finish()
        await h.api.finish(0, with: .success(try response(original)))
        XCTAssertEqual(h.queue.pendingMessages(chatID: "create").map(\.state), [.failed, .pending])
        h.queue.requestForegroundActive(true)
        try await eventually { await h.api.requests().count == 3 }
        let retried = await h.api.requests().dropFirst()
        XCTAssertEqual(
            retried.first(where: { $0.chatID == "create" })?.body.clientGeneratedId,
            original.body.clientGeneratedId)
        XCTAssertEqual(
            retried.first(where: { $0.chatID == "preflight" })?.body.clientGeneratedId, unhandedID)
    }

    func testDeniedGrantLeavesRowsQueuedForForegroundRecovery() async throws {
        let h = try await openHarness(foreground: false)
        h.background.granted = false
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "A")
        h.queue.requestForegroundActive(true)
        h.queue.requestForegroundActive(false)
        XCTAssertEqual(h.background.attempts, 1)
        h.queue.resynchronizePublications()
        XCTAssertEqual(h.background.attempts, 1)
        XCTAssertEqual(h.background.ended, 0)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.state, .pending)
        XCTAssertNotNil(h.queue.automaticBackgroundWakeDate)
        let inactive = await h.api.requests()
        XCTAssertTrue(inactive.isEmpty)
        h.queue.requestForegroundActive(true)
        try await eventually { await h.api.requests().count == 1 }
    }

    func testProcessExecutionDoesNotRequireAnActiveWindowOrNativeGrant() async throws {
        let h = try await openHarness(foreground: false, runsWhileInactive: true)
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "A")
        try await eventually { await h.api.requests().count == 1 }
        XCTAssertEqual(h.background.attempts, 0)
    }

    func testAccountHandoffSynchronouslyInvalidatesOldHTTPCompletion() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "old account", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        let first = try await firstRequest(h.api)
        var receivedOld = false
        let observation = h.queue.events.sink {
            if case .delivered(_, let message, _) = $0,
                message.clientGeneratedId == first.body.clientGeneratedId
            {
                receivedOld = true
            }
        }
        h.queue.requestSession(uid: 2)
        XCTAssertEqual(h.queue.storageState, .loading)
        XCTAssertEqual(h.queue.snapshots, [:])
        await h.queue.activate(uid: 2)
        XCTAssertEqual(h.queue.storageState, .ready)
        await h.api.finish(0, with: .success(try response(first)))
        XCTAssertFalse(receivedOld)
        XCTAssertEqual(h.queue.snapshots, [:])
        await h.queue.setForegroundActive(false)
        await h.queue.activate(uid: 1)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["old account"])
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat").first?.failure?.reason, .unknownOutcome)
        observation.cancel()
        await h.close()
    }

    func testRestartReplaysInterruptedHeadBeforeQueuedSuccessors() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.retry(
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID)
        try await eventually { await h.api.requests().count == 2 }
        let firstRun = await h.api.requests()
        await h.close()
        let second = try await openHarness(root: h.root, foreground: false)
        XCTAssertEqual(
            second.queue.pendingMessages(chatID: "chat").first?.failure?.reason, .unknownOutcome)
        XCTAssertThrowsError(try second.queue.beginPendingEdit(pendingProjection(rows[0])))
        try await second.queue.retry(chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID)
        await second.queue.setForegroundActive(true)
        try await eventually { await second.api.requests().count == 1 }
        var requests = await second.api.requests()
        XCTAssertEqual(requests[0].body, firstRun[1].body)
        for index in 0...2 {
            XCTAssertEqual(requests[index].body.clientGeneratedId, rows[index].clientGeneratedID)
            await second.api.finish(index, with: .success(try response(requests[index])))
            if index < 2 {
                try await eventually { await second.api.requests().count == index + 2 }
                requests = await second.api.requests()
            }
        }
        try await eventually { second.queue.pendingMessages(chatID: "chat").isEmpty }
        XCTAssertEqual(requests.map(\.body.message), ["A", "B", "C"])
        await second.close()
    }

    func testFailedReplyKeepsTargetAcrossRestartAndRetry() async throws {
        let h = try await openHarness()
        let reply = try TimelineTestFixtures.message(id: 100, at: 0).replyPreview
        try await h.queue.enqueueText(
            chatID: "chat", text: "answer", clearedDraftRevision: 1, replyToMessage: reply)
        try await eventually { await h.api.requests().count == 1 }
        let original = try await firstRequest(h.api)
        XCTAssertEqual(original.body.replyToId, reply.id)
        await h.api.finish(0, with: .failure(QueueTestError.rejected))
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
        await h.close()

        let restored = try await openHarness(root: h.root)
        XCTAssertEqual(restored.queue.pendingMessages(chatID: "chat").first?.replyToMessage, reply)
        try await restored.queue.retry(
            chatID: "chat", clientGeneratedID: original.body.clientGeneratedId)
        try await eventually { await restored.api.requests().count == 1 }
        let retried = try await firstRequest(restored.api)
        XCTAssertEqual(retried.body, original.body)
        await restored.api.finish(0, with: .success(try response(retried)))
        try await eventually { restored.queue.pendingMessages(chatID: "chat").isEmpty }
        await restored.close()
    }

    func testDraftSaveFailureDoesNotBlockSubmissionOrDispatchOfQueuedMessages() async throws {
        let h = try await openHarness()
        let drafts = ChatDraftStore(outgoingQueue: h.queue)
        let observation = h.queue.events.sink { event in
            if case .snapshot(let snapshot) = event { drafts.install(snapshot) }
        }
        defer {
            observation.cancel()
            drafts.reset()
        }
        try await h.queue.enqueueText(chatID: "chat", text: "first", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        let first = try await firstRequest(h.api)
        let reply = try TimelineTestFixtures.message(id: 100, at: 1).replyPreview
        drafts.setDraftText("send despite autosave failure", chatID: "chat")
        drafts.setDraftReply(reply, chatID: "chat")
        h.faults.failures = [.saveDraft]
        await drafts.flushDraft(chatID: "chat")
        XCTAssertTrue(drafts.draftSaveFailed)
        XCTAssertEqual(drafts.draftText(chatID: "chat"), "send despite autosave failure")

        let submitted = await drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(submitted)
        XCTAssertEqual(drafts.draftText(chatID: "chat"), "")
        await h.api.finish(0, with: .success(try response(first)))
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.body.message), ["first", "send despite autosave failure"])
        XCTAssertEqual(requests[1].body.replyToId, reply.id)
        await h.api.finish(1, with: .success(try response(requests[1])))
        try await eventually { h.queue.pendingMessages(chatID: "chat").isEmpty }
    }

    func testEnqueueAndClaimStorageFailuresNeverSendUncommittedWork() async throws {
        let h = try await openHarness()
        try await h.queue.saveDraft(
            chatID: "chat", text: "hello\n世界", editRevision: 1, updatedAt: Date())
        h.faults.failures = [.enqueue]
        do {
            try await h.queue.enqueueText(
                chatID: "chat", text: "hello\n世界", clearedDraftRevision: 2)
            XCTFail("Enqueue must fail before committing")
        } catch {}
        XCTAssertEqual(h.queue.snapshots[ConversationKey(chatID: "chat")]?.draft.text, "hello\n世界")
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
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.pending])
        h.faults.failures = []
        await h.queue.retryStorage()
        try await eventually { await h.api.requests().count == 1 }
        let resumed = await h.api.requests()
        XCTAssertEqual(resumed[0].body.message, "hello\n世界")
        await h.close()
    }

    func testAcknowledgementStorageFailureHidesDeliveryAndRecoversDeletionBeforeSuccessor()
        async throws
    {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        let first = try await firstRequest(h.api)
        let message = try response(first)
        var delivered: [MessageID] = []
        let observation = h.queue.events.sink {
            if case .delivered(_, let response, _) = $0 { delivered.append(response.id) }
        }
        h.faults.failures = [.acknowledge]
        await h.api.finish(0, with: .success(message))
        try await eventually { h.queue.storageState == .failed }
        XCTAssertTrue(delivered.isEmpty)
        let stale = await h.queue.acceptAcknowledgement(
            message.replacingMessageText("stale"), published: false)
        XCTAssertEqual(stale, .suppress)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["A", "B", "C"])
        let paused = await h.api.requests()
        XCTAssertEqual(paused.count, 1)
        h.faults.failures = []
        await h.queue.retryStorage()
        try await eventually { await h.api.requests().count == 2 }
        let resumed = await h.api.requests()
        XCTAssertEqual(delivered, [message.id])
        XCTAssertEqual(resumed[1].body.message, "B")
        XCTAssertFalse(
            h.queue.snapshots[ConversationKey(chatID: "chat")]!.outgoing.contains {
                $0.clientGeneratedID == message.clientGeneratedId
            })
        observation.cancel()
        await h.close()
        let store = try await h.openStore(uid: 1)
        let restored = try await store.restore()
        XCTAssertFalse(
            restored.flatMap(\.outgoing).contains {
                $0.clientGeneratedID == message.clientGeneratedId
            })
        let history = try await store.cachedHistory(.init(chatID: "chat"))
        XCTAssertEqual(history.messages, [message])
    }

    func testFailedFailureCommitIsRetriedAsFailureNotAsAutomaticNetworkRetry() async throws {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        h.faults.failures = [.fail]
        await h.api.finish(0, with: .failure(QueueTestError.rejected))
        try await eventually { h.queue.storageState == .failed }
        h.faults.failures = []
        await h.queue.retryStorage()
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat").map(\.state), [.failed, .pending, .pending])
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
        XCTAssertEqual(h.invalidTokenStates, [.failed, .pending, .pending])
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
        XCTAssertEqual(
            reopened.queue.pendingMessages(chatID: "chat").map(\.state),
            [.failed, .pending, .pending])
        await reopened.queue.setForegroundActive(false)
        XCTAssertNil(reopened.queue.automaticBackgroundWakeDate)
        XCTAssertEqual(reopened.background.attempts, 0)
        await reopened.queue.setForegroundActive(true)
        let requests = await reopened.api.requests()
        XCTAssertEqual(requests.count, 0)
        try await reopened.queue.retry(
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID)
        try await eventually { await reopened.api.requests().count == 1 }
        let retried = try await firstRequest(reopened.api)
        XCTAssertEqual(retried.body.clientGeneratedId, rows[0].clientGeneratedID)
        XCTAssertEqual(retried.body.message, "A")
        await reopened.close()
    }

    func testImmediateSameAccountReactivationRestoresWithoutWaitingForCancelledTransport()
        async throws
    {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        let original = try await firstRequest(h.api)
        h.queue.requestSession(uid: nil)
        h.queue.requestSession(uid: 1)
        XCTAssertEqual(h.queue.storageState, .loading)
        XCTAssertEqual(h.queue.snapshots, [:])
        h.queue.requestForegroundActive(false)
        await h.queue.activate(uid: 1)
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat").first?.failure?.reason, .unknownOutcome)
        let requests = await h.api.requests()
        XCTAssertEqual(requests.count, 1)
        await h.api.finish(0, with: .success(try response(original)))
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat").first?.clientGeneratedID,
            original.body.clientGeneratedId)
        await h.close()
    }

    func testRestoredMediaSendUsesSubmissionTimeAndKeepsSenderVisibleThroughAcknowledgement()
        async throws
    {
        let seed = try await openHarness(foreground: false)
        // A long-lived caption draft would previously sort between the two
        // earlier outgoing messages, hiding both its sender header and avatar.
        let key = ConversationKey(chatID: "chat")
        let localStore = try await seed.openStore(uid: 1)
        let file = localStore.directory.appendingPathComponent("image.png")
        try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: file)
        let uploaded = LocalOutgoingAttachment(
            id: "slot", generation: "generation", position: 0, sourcePath: file.path,
            preparedPath: file.path, previewPath: file.path, fileName: file.lastPathComponent,
            mimeType: "image/png", width: 1, height: 1, byteCount: 1, attachmentID: "image")
        _ = try await localStore.setDraftAttachments(
            key: key, attachments: [uploaded], compressionEnabled: true)
        _ = try await localStore.enqueueText(
            chatID: "chat", clientGeneratedID: "caption-send", text: "Caption",
            enqueuedAt: TimelineTestFixtures.date(second: 4), clearedDraftRevision: 1)
        await seed.close()
        let h = try await openHarness(root: seed.root, foreground: false)
        let chatStore = ChatStore(apiClient: h.api, outgoingQueue: h.queue, onInvalidToken: {})
        defer { chatStore.cancelRealtimeRecovery() }
        chatStore.currentUserProfile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":1,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))

        let history = try [
            TimelineTestFixtures.message(id: 1, at: 0),
            TimelineTestFixtures.message(id: 2, at: 2),
            TimelineTestFixtures.message(id: 3, senderID: 2, at: 3),
        ]
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
        let native = TimelineRowView(frame: .zero)
        let actions = TimelineBubbleActions()
        func assertSenderVisible(remote: [MessageResponse]) throws -> TimelineMessageRow {
            // Model order: confirmed messages, then unacknowledged sends in outbox order.
            let confirmedIDs = Set(remote.map(\.clientGeneratedId))
            let pending = chatStore.conversationMessages.pending(chatID: "chat").filter {
                !confirmedIDs.contains($0.clientGeneratedID)
            }
            let rows = TimelineRowsBuilder(currentUserID: 1, calendar: .current)
                .build(remote.map(ConversationTimelineEntry.remote) + pending.map { .pending($0) })
            let row = try XCTUnwrap(
                rows.compactMap { row -> TimelineMessageRow? in
                    guard case .message(let message) = row,
                        message.entry.stableKey == TimelineTestFixtures.stableKey("caption-send")
                    else { return nil }
                    return message
                }.first)
            XCTAssertEqual(row.groupPosition, .single)
            let presentation = TimelineRowPresentation.make(
                row: .message(row), currentUserID: 1,
                isThreadTimeline: false, environment: environment)
            XCTAssertEqual(presentation.title?.name, "Ada")
            let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
            XCTAssertNotNil(layout.frames[.title])
            XCTAssertNotNil(layout.frames[.avatar])
            native.frame = CGRect(origin: .zero, size: layout.size)
            native.bind(
                .init(
                    presentation: presentation, layout: layout, context: .init(),
                    actions: actions, mediaContext: nil))
            #if os(macOS)
                native.layoutSubtreeIfNeeded()
                let avatar = try XCTUnwrap(
                    native.subviews.compactMap { $0 as? TimelineAvatarView }.first)
                XCTAssertFalse(avatar.isHidden)
                XCTAssertTrue(avatar.accessibilityLabel()?.contains("Ada") == true)
            #elseif os(iOS)
                native.layoutIfNeeded()
                let avatar = try XCTUnwrap(
                    native.subviews.flatMap(\.subviews).compactMap { $0 as? TimelineAvatarView }
                        .first)
                XCTAssertFalse(avatar.isHidden)
                XCTAssertTrue(avatar.accessibilityLabel?.contains("Ada") == true)
            #endif
            return row
        }
        let pending = try assertSenderVisible(remote: history)
        XCTAssertEqual(pending.entry.displayState, .queued)
        let acknowledgement = try TimelineTestFixtures.message(
            id: 4, at: 5, text: "Caption",
            clientGeneratedID: "caption-send",
            fields: [
                "hasAttachments": true,
                "attachments": [
                    [
                        "id": "image", "url": "https://example.invalid/image.png",
                        "kind": "image/png",
                        "size": 1, "fileName": "image.png", "width": 1, "height": 1,
                    ]
                ],
            ])
        h.queue.authorizeWrite = nil
        await h.queue.setForegroundActive(true)
        try await eventually { await h.api.requests().count == 1 }
        let accepted = await h.queue.acceptAcknowledgement(acknowledgement)
        XCTAssertEqual(accepted, .consumed)
        let confirmed = try assertSenderVisible(remote: history + [acknowledgement])
        XCTAssertEqual(confirmed.entry.stableKey, pending.entry.stableKey)
        XCTAssertEqual(confirmed.entry.displayState, .delivered)
    }

    func testDiscardDraftAttachmentsPreservesCaptionReplyAndPendingSendsAcrossRestart() async throws
    {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(
            chatID: "chat", threadID: "thread", text: "thread send", clearedDraftRevision: 1)
        try await h.queue.enqueueText(chatID: "chat", text: "parent send", clearedDraftRevision: 1)
        try await h.queue.enqueueText(chatID: "other", text: "other send", clearedDraftRevision: 1)
        try await h.queue.saveDraft(
            chatID: "chat", text: "parent draft", editRevision: 2, updatedAt: Date())
        let reply = try TimelineTestFixtures.message(id: 100, at: 0).replyPreview
        let caption = "keep this caption\n世界"
        try await h.queue.saveDraft(
            chatID: "chat", threadID: "thread", text: caption, editRevision: 2,
            updatedAt: Date(), replyToMessage: reply)
        let image = h.root.appendingPathComponent("selected.png")
        try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: image)
        try await h.queue.importImages(urls: [image, image], chatID: "chat", threadID: "thread")
        let key = ConversationKey(chatID: "chat", threadID: "thread")
        await h.queue.setForegroundActive(true)
        try await eventually { await h.api.requests().count == 3 }
        let sending = h.queue.snapshots.mapValues(\.outgoing)
        let parentDraft = h.queue.snapshots[ConversationKey(chatID: "chat")]?.draft

        try await h.queue.discardDraftAttachments(chatID: "chat", threadID: "thread")

        XCTAssertEqual(h.queue.snapshots.mapValues(\.outgoing), sending)
        XCTAssertEqual(h.queue.snapshots[ConversationKey(chatID: "chat")]?.draft, parentDraft)
        let discarded = try XCTUnwrap(h.queue.snapshots[key])
        XCTAssertTrue(discarded.draft.attachments.isEmpty)
        XCTAssertTrue(h.queue.draftAttachments(chatID: "chat", threadID: "thread").isEmpty)
        XCTAssertEqual(discarded.draft.text, caption)
        XCTAssertEqual(discarded.draft.replyToMessage, reply)
        await h.close()

        let reopened = try await openHarness(root: h.root, foreground: false)
        let restored = try XCTUnwrap(reopened.queue.snapshots[key])
        assertDraftContent(restored.draft, discarded.draft)
        XCTAssertEqual(
            reopened.queue.snapshots.mapValues { $0.outgoing.map(\.body) },
            sending.mapValues { $0.map(\.body) })
        let drafts = ChatDraftStore(outgoingQueue: reopened.queue)
        for snapshot in reopened.queue.snapshots.values { drafts.install(snapshot) }
        XCTAssertEqual(drafts.draftText(chatID: "chat", threadID: "thread"), caption)
        XCTAssertTrue(reopened.queue.draftAttachments(chatID: "chat", threadID: "thread").isEmpty)
    }

    func testReorderingCompletedAttachmentsDispatchesExistingIDsInLatestOrder() async throws {
        let seed = try await openHarness(foreground: false)
        let store = try await seed.openStore(uid: 1)
        let slots = try (0..<2).map { index in
            let file = store.directory.appendingPathComponent("slot-\(index).png")
            try Data([1, 2, 3]).write(to: file, options: .atomic)
            return LocalOutgoingAttachment(
                id: "slot-\(index)", generation: UUID().uuidString, position: index,
                sourcePath: file.path, preparedPath: file.path, previewPath: file.path,
                fileName: file.lastPathComponent, mimeType: "image/png",
                width: 10, height: 10, byteCount: 3, attachmentID: "remote-\(index)")
        }
        _ = try await store.setDraftAttachments(
            key: .init(chatID: "chat"), attachments: slots, compressionEnabled: true)
        await seed.close()
        let h = try await openHarness(root: seed.root, foreground: false)

        try await h.queue.reorderAttachments(ids: ["slot-1", "slot-0"], chatID: "chat")
        let revision = try XCTUnwrap(
            h.queue.snapshots[ConversationKey(chatID: "chat", threadID: nil)]?.draft.editRevision)
        try await h.queue.enqueueText(chatID: "chat", text: "", clearedDraftRevision: revision + 1)
        await h.queue.setForegroundActive(true)
        // This API cannot allocate uploads: dispatch proves neither completed slot was restarted.
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        XCTAssertEqual(request.body.attachmentIds, ["remote-1", "remote-0"])
    }

    func testExclusiveEditorSurvivesFailedSaveAndRejectsOtherLocalMutation() async throws {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let editor = try h.queue.beginPendingEdit(pendingProjection(item))
        XCTAssertThrowsError(try h.queue.beginPendingEdit(pendingProjection(item)))
        do {
            try await h.queue.removeOutgoing(chatID: "chat", itemID: item.clientGeneratedID)
            XCTFail("Removal cannot win against an open editor")
        } catch {}
        h.faults.failures = [.edit]
        do {
            try await h.queue.submitPendingEdit(editor, text: "changed", metadata: nil)
            XCTFail("Expected durable edit failure")
        } catch {}
        XCTAssertTrue(editor.isValid)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.text, "original")
        h.faults.failures = []
        await h.queue.retryStorage()
        try await h.queue.submitPendingEdit(editor, text: "changed", metadata: nil)
        XCTAssertFalse(editor.isValid)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.text, "changed")
    }

    func testCancelEditorReleasesOnlyNewImportsAndSubmitTransfersSelectedImports() async throws {
        let h = try await openHarness(foreground: false)
        let image = h.root.appendingPathComponent("image.png")
        try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: image)
        try await h.queue.importImages(urls: [image], chatID: "chat")
        try await h.queue.enqueueText(chatID: "chat", text: "caption", clearedDraftRevision: 2)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let borrowed = try XCTUnwrap(item.attachments.first)
        let session = try h.queue.beginPendingEdit(pendingProjection(item))
        try await h.queue.importEditAttachments(urls: [image], session: session, asFiles: false)
        let imported = try XCTUnwrap(session.attachments.last)
        h.queue.removeEditAttachment(id: borrowed.id, session: session)
        h.queue.endPendingEdit(session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: borrowed.sourcePath))
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.attachments, [borrowed])
        XCTAssertFalse(
            h.queue.pendingMessages(chatID: "chat").first?.attachments.contains(imported) ?? true)
        let replacement = try h.queue.beginPendingEdit(pendingProjection(item))
        try await h.queue.importEditAttachments(urls: [image], session: replacement, asFiles: false)
        let committed = try XCTUnwrap(replacement.attachments.last)
        h.queue.removeEditAttachment(id: borrowed.id, session: replacement)
        try await h.queue.submitPendingEdit(replacement, text: "", metadata: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.sourcePath))
        XCTAssertFalse(replacement.isValid)
        await h.close()
        let reopened = try await openHarness(root: h.root, foreground: false)
        let restored = try XCTUnwrap(
            reopened.queue.pendingMessages(chatID: "chat").first?.attachments.first)
        XCTAssertEqual(restored.sourcePath, committed.sourcePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.sourcePath))
    }

    func testPendingEditPersistsMetadataOnlyChangeAndSeedsNextEditor() async throws {
        let h = try await openHarness(foreground: false)
        let text = "https://example.com"
        try await h.queue.enqueueText(chatID: "chat", text: text, clearedDraftRevision: 1)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let session = try h.queue.beginPendingEdit(pendingProjection(item))
        let metadata = MessageMetadataInput(
            linkPreviews: [.init(url: text, status: .disabled)])
        XCTAssertFalse(session.hasChanges(text: text))
        XCTAssertTrue(session.hasChanges(text: text, metadata: metadata))
        try await h.queue.submitPendingEdit(session, text: text, metadata: metadata)
        let changed = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        XCTAssertEqual(changed.text, text)
        XCTAssertEqual(changed.metadata, metadata)
        XCTAssertEqual(changed.clientGeneratedID, item.clientGeneratedID)
        let next = try h.queue.beginPendingEdit(pendingProjection(changed))
        XCTAssertEqual(next.initialMetadata, metadata)
        XCTAssertFalse(next.hasChanges(text: text, metadata: metadata))
        XCTAssertTrue(next.hasChanges(text: text, metadata: .init()))
        await h.close()
        let reopened = try await openHarness(root: h.root, foreground: false)
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "chat").first?.metadata, metadata)
    }

    func testEditorMediaLimitAndUnchangedWhitespaceRejectWithoutLosingSession() async throws {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(chatID: "chat", text: "caption", clearedDraftRevision: 1)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let session = try h.queue.beginPendingEdit(pendingProjection(item))
        XCTAssertFalse(session.hasChanges(text: " \ncaption\n "))
        do {
            try await h.queue.importEditAttachments(
                urls: Array(repeating: h.root.appendingPathComponent("unused.png"), count: 21),
                session: session, asFiles: false)
            XCTFail("Expected attachment limit")
        } catch LocalStorageError.invalidAttachments {}
        XCTAssertTrue(session.attachments.isEmpty)
        XCTAssertTrue(session.isValid)
        do {
            try await h.queue.submitPendingEdit(session, text: "  caption  ", metadata: nil)
            XCTFail("Expected unchanged edit rejection")
        } catch {}
        XCTAssertTrue(session.isValid)
        await h.queue.activate(uid: 2)
        XCTAssertFalse(session.isValid)
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
    }

    func testEditorHoldsPreparingFIFOHeadAndPreservesMatchingInFlightCheckpoints() async throws {
        for save in [true, false] {
            let h = try await openHarness(foreground: false)
            let image = h.root.appendingPathComponent("image.png")
            try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: image)
            try await h.queue.importImages(urls: [image, image, image], chatID: "chat")
            try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
            try await h.queue.enqueueIndependentText(chatID: "chat", text: "B")
            try await h.queue.enqueueIndependentText(chatID: "other", text: "C")
            await h.api.enableUploads()
            await h.queue.setForegroundActive(true)
            try await eventually { await h.api.uploadCount() == 2 }
            let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
            guard case .preparing = h.queue.phase(of: item) else {
                return XCTFail("An uploading FIFO head must remain Preparing")
            }
            let editor = try h.queue.beginPendingEdit(pendingProjection(item))
            await h.api.finishUpload("remote-0")
            await h.api.finishUpload("remote-1")
            try await eventually {
                editor.attachments.compactMap(\.attachmentID) == ["remote-0", "remote-1"]
            }
            let whileHeld = await h.api.requests()
            XCTAssertEqual(whileHeld.map(\.body.message), ["C"])
            let heldUploads = await h.api.uploadCount()
            XCTAssertEqual(heldUploads, 2, "Do not start uploads for the held message")
            if save {
                h.queue.removeEditAttachment(id: editor.attachments[2].id, session: editor)
                try h.queue.reorderEditAttachments(
                    ids: Array(editor.attachments.map(\.id).reversed()), session: editor)
                let reply = try TimelineTestFixtures.message(id: 42, at: 0).replyPreview
                editor.setReplyToMessage(reply)
                try await h.queue.submitPendingEdit(editor, text: "edited A", metadata: nil)
            } else {
                h.queue.endPendingEdit(editor)
                try await eventually { await h.api.uploadCount() == 3 }
                await h.api.finishUpload("remote-2")
            }
            try await eventually { await h.api.requests().count == 2 }
            let head = await h.api.requests()[1]
            XCTAssertEqual(head.body.message, save ? "edited A" : "A")
            XCTAssertEqual(head.body.replyToId, save ? MessageID(42) : nil)
            XCTAssertEqual(
                head.body.attachmentIds,
                save ? ["remote-1", "remote-0"] : ["remote-0", "remote-1", "remote-2"])
            XCTAssertEqual(head.body.clientGeneratedId, item.clientGeneratedID)
            await h.api.finish(1, with: .success(try response(head)))
            try await eventually { await h.api.requests().count == 3 }
            let sends = await h.api.requests()
            XCTAssertEqual(sends.map(\.body.message), ["C", save ? "edited A" : "A", "B"])
        }
    }

    func testRemovingPreparingHeadOfflineFencesLateUpload() async throws {
        let h = try await openHarness(foreground: false)
        let image = h.root.appendingPathComponent("image.png")
        try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: image)
        try await h.queue.importImages(urls: [image], chatID: "chat")
        try await h.queue.enqueueText(chatID: "chat", text: "remove", clearedDraftRevision: 1)
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "keep")
        await h.api.enableUploads()
        await h.queue.setForegroundActive(true)
        try await eventually { await h.api.uploadCount() == 1 }
        let head = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        h.queue.setNetworkReachable(false)
        try await h.queue.removeOutgoing(chatID: "chat", itemID: head.clientGeneratedID)
        await h.api.finishUpload("remote-0")
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["keep"])
        h.queue.setNetworkReachable(true)
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        XCTAssertEqual(request.body.message, "keep")
        XCTAssertTrue(request.body.attachmentIds.isEmpty)
        let mutations = await h.api.serverMutationCalls()
        XCTAssertEqual(mutations, 0)
    }

    func testAmbiguousCreateRequiresConfirmationToRemoveOffline() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "possibly delivered")
        try await eventually { await h.api.requests().count == 1 }
        h.queue.setNetworkReachable(false)
        await h.api.finish(0, with: .failure(APIError.transport(URLError(.timedOut))))
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
        let head = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        do {
            try await h.queue.removeOutgoing(chatID: "chat", itemID: head.clientGeneratedID)
            XCTFail("An ambiguous create requires explicit confirmation")
        } catch OutgoingMessageQueue.QueueError.possibleDelivery {}
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat"), [head])
        try await h.queue.removeOutgoing(
            chatID: "chat", itemID: head.clientGeneratedID, allowPossibleDelivery: true)
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        let mutations = await h.api.serverMutationCalls()
        XCTAssertEqual(mutations, 0)
    }

    func testOldOrMismatchedConflictKeepsHeadFailedUntilLocalRemoval() async throws {
        for mismatched in [false, true] {
            let h = try await openHarness()
            let rows = try await enqueueABC(h)
            XCTAssertThrowsError(try h.queue.beginPendingEdit(pendingProjection(rows[0])))
            do {
                try await h.queue.removeOutgoing(chatID: "chat", itemID: rows[0].clientGeneratedID)
                XCTFail("Cannot remove an active create")
            } catch {}
            let first = try await firstRequest(h.api)
            let conflict: Data
            if mismatched {
                let unrelated = try TimelineTestFixtures.message(
                    id: 80, senderID: 2, at: 0, clientGeneratedID: first.body.clientGeneratedId)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                conflict = try JSONSerialization.data(withJSONObject: [
                    "code": "clientGeneratedIdConflict",
                    "existingMessage": try JSONSerialization.jsonObject(
                        with: encoder.encode(unrelated)),
                ])
            } else {
                conflict = Data("clientGeneratedId already exists".utf8)
            }
            await h.api.finish(0, with: .failure(APIError.http(status: 409, body: conflict)))
            try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
            XCTAssertThrowsError(try h.queue.beginPendingEdit(pendingProjection(rows[0])))
            h.queue.resynchronizePublications()
            let failed = await h.api.requests()
            XCTAssertEqual(failed.count, 1)
            try await h.queue.removeOutgoing(chatID: "chat", itemID: rows[0].clientGeneratedID)
            try await eventually { await h.api.requests().count == 2 }
            let requests = await h.api.requests()
            XCTAssertEqual(requests.map(\.body.message), ["A", "B"])
            let mutationCount = await h.api.serverMutationCalls()
            XCTAssertEqual(mutationCount, 0)
            let echo = await h.queue.acceptAcknowledgement(try response(first))
            XCTAssertEqual(echo, .unrelated)
        }
    }

    func testOfflineBeforeHandoffRestoresPendingWithoutChangingRequest() async throws {
        let h = try await openHarness()
        h.faults.hold = .acknowledge
        h.queue.authorizeWrite = { [faults = h.faults] _, _ in
            try await faults.check(.acknowledge)
        }
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "keep")
        try await eventually { h.faults.isHoldingOperation }
        let claimed = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        XCTAssertEqual(claimed.state, .sending)
        h.queue.setNetworkReachable(false)
        h.faults.release()
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .pending }
        let offline = await h.api.requests()
        XCTAssertTrue(offline.isEmpty)
        h.queue.setNetworkReachable(true)
        try await eventually { await h.api.requests().count == 1 }
        let first = try await firstRequest(h.api)
        XCTAssertEqual(first.body, claimed.body)
    }

    func testPreflightTransportFailureReleasesClaimAndBacksOffWithoutLosingIntent() async throws {
        let h = try await openHarness()
        var checks = 0
        h.queue.authorizeWrite = { chatID, _ in
            guard chatID == "chat" else { return }
            checks += 1
            if checks == 1 { throw APIError.transport(URLError(.timedOut)) }
        }
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "keep")
        try await eventually {
            checks == 1 && h.queue.pendingMessages(chatID: "chat").first?.state == .pending
        }
        let pending = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let unsent = await h.api.requests()
        XCTAssertTrue(unsent.isEmpty)
        try await h.queue.enqueueIndependentText(chatID: "other", text: "independent")
        try await eventually { await h.api.requests().count == 1 }
        let independent = try await firstRequest(h.api)
        XCTAssertEqual(independent.chatID, "other")
        h.queue.setNetworkReachable(false)
        h.queue.setNetworkReachable(true)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(requests[1].body, pending.body)
    }

    func testOfflineEnqueuePermissionIsSeparateFromAuthoritativePreflight() async throws {
        let h = try await openHarness()
        h.queue.setNetworkReachable(false)
        h.queue.authorizeEnqueue = { _ in throw QueueTestError.rejected }
        let key = ConversationKey(chatID: "chat", threadID: "thread")
        try await h.queue.saveDraft(
            chatID: key.chatID, threadID: key.threadID, text: "draft", editRevision: 1,
            updatedAt: Date())
        do {
            try await h.queue.enqueueText(
                chatID: key.chatID, threadID: key.threadID, text: "draft", clearedDraftRevision: 2)
            XCTFail("Denied local submission must not clear the draft")
        } catch QueueTestError.rejected {}
        XCTAssertEqual(h.queue.snapshots[key]?.draft.text, "draft")
        XCTAssertTrue(h.queue.pendingMessages(chatID: key.chatID, threadID: key.threadID).isEmpty)
        XCTAssertEqual(h.queue.storageState, .ready)

        var checkedDestinations: [ConversationKey] = []
        h.queue.authorizeEnqueue = { checkedDestinations.append($0) }
        h.queue.authorizeWrite = { chatID, _ in
            if chatID == key.chatID { throw QueueTestError.rejected }
        }
        try await h.queue.enqueueText(
            chatID: key.chatID, threadID: key.threadID, text: "draft", clearedDraftRevision: 2)
        XCTAssertEqual(checkedDestinations, [key])
        XCTAssertEqual(h.queue.snapshots[key]?.draft.text, "")
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: key.chatID, threadID: key.threadID).first?.state,
            .pending)

        h.queue.setNetworkReachable(true)
        try await h.queue.enqueueIndependentText(chatID: "other", text: "independent")
        try await eventually {
            h.queue.pendingMessages(chatID: key.chatID, threadID: key.threadID).first?.failure?
                .reason == .rejected
        }
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        XCTAssertEqual(request.chatID, "other")
    }

    func testNetworkFailureRetriesOriginalBodyOnBackoffAndRecovery() async throws {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        let first = try await firstRequest(h.api)
        let failed = APIError.transport(URLError(.timedOut))
        await h.api.finish(0, with: .failure(failed))
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
        let pending = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        guard case .failed(let failure, let retryDate) = h.queue.phase(of: pending) else {
            return XCTFail("Timeout must be visible before retrying")
        }
        XCTAssertEqual(failure.retry, .automatic)
        XCTAssertNotNil(retryDate)
        try await eventually { await h.api.requests().count == 2 }
        await h.api.finish(1, with: .failure(failed))
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
        h.queue.setNetworkReachable(false)
        h.queue.setNetworkReachable(true)
        h.queue.resynchronizePublications()
        try await eventually { await h.api.requests().count == 3 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.body), Array(repeating: first.body, count: 3))
        await h.api.finish(2, with: .success(try response(requests[2])))
        try await eventually { await h.api.requests().count == 4 }
        let successor = await h.api.requests()[3]
        XCTAssertEqual(successor.body.message, "B")
    }

    func testRetryAfterSurvivesReconnectManualRetryAndRestart() async throws {
        let h = try await openHarness()
        let rows = try await enqueueABC(h)
        let date = Date().addingTimeInterval(60)
        await h.api.finish(
            0,
            with: .failure(
                APIError.retryableHTTP(
                    status: 429, body: Data(), retryAfter: date)))
        try await eventually {
            guard let item = h.queue.pendingMessages(chatID: "chat").first,
                case .failed(_, let nextRetry) = h.queue.phase(of: item), let nextRetry
            else { return false }
            return abs(nextRetry.timeIntervalSince(date)) < 0.5
        }
        h.queue.requestForegroundActive(false)
        let wake = try XCTUnwrap(h.queue.automaticBackgroundWakeDate)
        XCTAssertEqual(wake.timeIntervalSince(date), 0, accuracy: 0.5)
        let early = await h.queue.drainScheduledRefresh()
        XCTAssertFalse(early)
        XCTAssertEqual(h.background.attempts, 0)
        h.queue.requestForegroundActive(true)
        h.queue.setNetworkReachable(false)
        h.queue.setNetworkReachable(true)
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID)
        try await h.queue.enqueueIndependentText(chatID: "other", text: "independent")
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.body.message), ["A", "independent"])
        await h.api.finish(1, with: .success(try response(requests[1])))
        try await eventually { h.queue.pendingMessages(chatID: "other").isEmpty }
        await h.close()

        let reopened = try await openHarness(root: h.root, foreground: false)
        let restored = try XCTUnwrap(reopened.queue.pendingMessages(chatID: "chat").first)
        XCTAssertEqual(restored.clientGeneratedID, rows[0].clientGeneratedID)
        XCTAssertEqual(
            try XCTUnwrap(restored.retryNotBefore).timeIntervalSince(date), 0, accuracy: 0.001)
        let restoredWake = try XCTUnwrap(reopened.queue.automaticBackgroundWakeDate)
        XCTAssertEqual(restoredWake.timeIntervalSince(date), 0, accuracy: 0.001)
        let scheduledEarly = await reopened.queue.drainScheduledRefresh()
        XCTAssertFalse(scheduledEarly)
        reopened.queue.requestForegroundActive(true)
        reopened.queue.setNetworkReachable(false)
        try await reopened.queue.retry(
            chatID: "chat", clientGeneratedID: restored.clientGeneratedID)
        reopened.queue.setNetworkReachable(true)
        try await reopened.queue.enqueueIndependentText(
            chatID: "other", text: "independent after restore")
        try await eventually { await reopened.api.requests().count == 1 }
        let untouched = await reopened.api.requests()
        XCTAssertEqual(untouched.map(\.chatID), ["other"])
    }

    func testPreflightRetryAfterRestoresPendingWithoutStartingASecondPreflight() async throws {
        let h = try await openHarness()
        let deadline = Date().addingTimeInterval(60)
        h.queue.authorizeWrite = { _, _ in
            throw APIError.retryableHTTP(status: 503, body: Data(), retryAfter: deadline)
        }
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "unchanged")
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").first?.retryNotBefore != nil
        }
        let queued = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        XCTAssertEqual(queued.state, .pending)
        let beforeRestart = await h.api.requests()
        XCTAssertTrue(beforeRestart.isEmpty)
        await h.close()

        let reopened = try await openHarness(root: h.root, foreground: false)
        var preflights: [String] = []
        reopened.queue.authorizeWrite = { chatID, _ in preflights.append(chatID) }
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "chat").first, queued)
        let scheduledEarly = await reopened.queue.drainScheduledRefresh()
        XCTAssertFalse(scheduledEarly)
        reopened.queue.setNetworkReachable(false)
        reopened.queue.requestForegroundActive(true)
        reopened.queue.setNetworkReachable(true)
        try await reopened.queue.enqueueIndependentText(chatID: "other", text: "independent")
        try await eventually { await reopened.api.requests().count == 1 }
        XCTAssertEqual(preflights, ["other"])
    }

    func testLocalRetryJitterSetsTheFloorWhenRetryAfterIsEarlier() async throws {
        var jitteredAt: Date?
        let h = try await openHarness(retryJitter: {
            jitteredAt = Date()
            return 0.2
        })
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "same request")
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        await h.api.finish(
            0,
            with: .failure(
                APIError.retryableHTTP(
                    status: 429, body: Data(), retryAfter: Date().addingTimeInterval(0.1))))
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
        let retryTime = try XCTUnwrap(h.queue.automaticBackgroundWakeDate)
        XCTAssertEqual(retryTime.timeIntervalSince(try XCTUnwrap(jitteredAt)), 1.2, accuracy: 0.08)
        h.queue.setNetworkReachable(false)
        h.queue.setNetworkReachable(true)
        try await eventually { await h.api.requests().count == 2 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(retryTime), -0.05)
        let requests = await h.api.requests()
        XCTAssertEqual(requests[1].body, request.body)
    }

    func testBackgroundReplyCannotBypassFIFOAndExpirationFencesLateHTTP() async throws {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueIndependentText(chatID: "blocked", text: "older")
        let older = try XCTUnwrap(h.queue.pendingMessages(chatID: "blocked").first)
        let editor = try h.queue.beginPendingEdit(pendingProjection(older))
        defer { h.queue.endPendingEdit(editor) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        try await h.queue.enqueueIndependentText(
            chatID: "blocked", text: "blocked reply", notificationDeadline: deadline)
        try await h.queue.enqueueIndependentText(
            chatID: "expired", text: "expired reply",
            notificationDeadline: ContinuousClock.now.advanced(by: .seconds(-1)))
        let expired = try XCTUnwrap(h.queue.pendingMessages(chatID: "expired").first)
        XCTAssertEqual(h.background.attempts, 0)
        try await h.queue.removeOutgoing(chatID: "expired", itemID: expired.clientGeneratedID)
        try await h.queue.enqueueIndependentText(
            chatID: "allowed", text: "reply", notificationDeadline: deadline)
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        XCTAssertEqual(request.chatID, "allowed")
        let live = try XCTUnwrap(h.background.expirations.first)
        live()
        try await eventually {
            h.queue.pendingMessages(chatID: "allowed").first?.failure?.reason == .unknownOutcome
        }
        let message = try response(request)
        await h.api.finish(0, with: .success(message))
        XCTAssertEqual(h.queue.pendingMessages(chatID: "allowed").first?.state, .failed)
        let receipt = await h.queue.acceptAcknowledgement(message)
        XCTAssertEqual(receipt, .consumed)
        XCTAssertTrue(h.queue.pendingMessages(chatID: "allowed").isEmpty)
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "blocked").map(\.text), ["older", "blocked reply"])
        XCTAssertEqual(h.background.ended, 1)
    }

    func testScheduledRefreshCompletionAndCancellationShareTheDispatcher() async throws {
        let h = try await openHarness(foreground: false)
        let empty = await h.queue.drainScheduledRefresh()
        XCTAssertTrue(empty)
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "A")
        h.queue.setNetworkReachable(false)
        let deferred = await h.queue.drainScheduledRefresh()
        XCTAssertFalse(deferred)
        XCTAssertNotNil(h.queue.automaticBackgroundWakeDate)
        h.queue.setNetworkReachable(true)
        let refresh = Task { await h.queue.drainScheduledRefresh() }
        try await eventually { await h.api.requests().count == 1 }
        let duplicate = await h.queue.drainScheduledRefresh()
        XCTAssertFalse(duplicate)
        refresh.cancel()
        let cancelled = await refresh.value
        XCTAssertFalse(cancelled)
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").first?.failure?.reason == .unknownOutcome
        }
        let original = try await firstRequest(h.api)
        await h.api.finish(0, with: .success(try response(original)))
        let requests = await h.api.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(h.background.attempts, 0)
    }

    func testBackgroundAttachmentExpiryPreservesSuccessfulUploadAndIgnoresDraft() async throws {
        let h = try await openHarness(foreground: false)
        let image = h.root.appendingPathComponent("image.png")
        try makeMediaPNG(red: 40, green: 30, blue: 20).write(to: image)
        try await h.queue.importImages(urls: [image], chatID: "draft")
        XCTAssertNil(h.queue.automaticBackgroundWakeDate)
        let draftOnly = await h.queue.drainScheduledRefresh()
        XCTAssertTrue(draftOnly)
        try await h.queue.importImages(urls: [image, image], chatID: "submitted")
        try await h.queue.enqueueText(chatID: "submitted", text: "A", clearedDraftRevision: 1)
        await h.api.enableUploads()
        h.queue.requestForegroundActive(true)
        h.queue.requestForegroundActive(false)
        try await eventually { await h.api.uploadCount() == 2 }
        let expire = try XCTUnwrap(h.background.expirations.first)
        expire()
        await h.api.finishUpload("remote-0")
        await h.api.finishUpload("remote-1", with: .failure(CancellationError()))
        try await eventually {
            h.queue.pendingMessages(chatID: "submitted").first?.attachments.map(\.attachmentID)
                == ["remote-0", nil]
        }
        XCTAssertEqual(h.background.ended, 1)
        XCTAssertNil(h.queue.draftAttachments(chatID: "draft").first?.preparedPath)
        let initial = await h.api.requests()
        XCTAssertTrue(initial.isEmpty)
        try await h.queue.discardDraftAttachments(chatID: "draft")
        let refresh = Task { await h.queue.drainScheduledRefresh() }
        try await eventually { await h.api.uploadCount() == 3 }
        await h.api.finishUpload("remote-1")
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        await h.api.finish(0, with: .success(try response(request)))
        let completed = await refresh.value
        XCTAssertTrue(completed)
        XCTAssertNil(h.queue.automaticBackgroundWakeDate)
    }

    func testFailedPreparationRetryKeepsUploadedSlotsAndWaitsForHead() async throws {
        let h = try await openHarness(foreground: false)
        let image = h.root.appendingPathComponent("image.png")
        try makeMediaPNG(red: 40, green: 30, blue: 20).write(to: image)
        try await h.queue.importImages(urls: [image, image], chatID: "chat")
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        try await h.queue.enqueueIndependentText(chatID: "chat", text: "B")
        await h.api.enableUploads()
        h.queue.requestForegroundActive(true)
        try await eventually { await h.api.uploadCount() == 2 }
        await h.api.finishUpload("remote-0")
        await h.api.finishUpload(
            "remote-1", with: .failure(APIError.transport(URLError(.timedOut))))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").first?.failure?.stage == .preparation
        }
        let paused = await h.api.requests()
        XCTAssertTrue(paused.isEmpty)
        try await eventually { await h.api.uploadCount() == 3 }
        await h.api.finishUpload("remote-1")
        try await eventually { await h.api.requests().count == 1 }
        let first = try await firstRequest(h.api)
        XCTAssertEqual(first.body.message, "A")
        XCTAssertEqual(first.body.attachmentIds, ["remote-0", "remote-1"])
    }

    func testUploadRetryAfterRetainsOtherCheckpointAndBlocksManualRetryAfterRestart() async throws {
        let h = try await openHarness(foreground: false)
        let image = h.root.appendingPathComponent("image.png")
        try makeMediaPNG(red: 40, green: 30, blue: 20).write(to: image)
        try await h.queue.importImages(urls: [image, image], chatID: "chat")
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        await h.api.enableUploads()
        h.queue.requestForegroundActive(true)
        try await eventually { await h.api.uploadCount() == 2 }
        h.queue.setNetworkReachable(false)
        let deadline = Date().addingTimeInterval(60)
        await h.api.finishUpload(
            "remote-1",
            with: .failure(
                OutgoingAttachmentUploadError.httpStatus(
                    429, retryAfter: deadline)))
        await h.api.finishUpload("remote-0")
        try await eventually {
            guard let row = h.queue.pendingMessages(chatID: "chat").first else { return false }
            return row.failure?.stage == .preparation
                && row.attachments.first?.attachmentID == "remote-0"
        }
        await h.close()

        let reopened = try await openHarness(root: h.root, foreground: false)
        await reopened.api.enableUploads()
        let restored = try XCTUnwrap(reopened.queue.pendingMessages(chatID: "chat").first)
        XCTAssertEqual(restored.attachments.map(\.attachmentID), ["remote-0", nil])
        XCTAssertEqual(restored.attachments.map(\.retryNotBefore), [nil, deadline])
        let wake = try XCTUnwrap(reopened.queue.automaticBackgroundWakeDate)
        XCTAssertEqual(wake.timeIntervalSince(deadline), 0, accuracy: 0.001)
        let scheduledEarly = await reopened.queue.drainScheduledRefresh()
        XCTAssertFalse(scheduledEarly)
        reopened.queue.requestForegroundActive(true)
        reopened.queue.setNetworkReachable(false)
        try await reopened.queue.retry(
            chatID: "chat", clientGeneratedID: restored.clientGeneratedID)
        reopened.queue.setNetworkReachable(true)
        try await reopened.queue.enqueueIndependentText(chatID: "other", text: "independent")
        try await eventually { await reopened.api.requests().count == 1 }
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "chat").first, restored)
        let uploads = await reopened.api.uploadCount()
        XCTAssertEqual(uploads, 0)
    }

    func testSignOutFencePurgesOnlyThisAccountAndRetriesFailedPurge() async throws {
        let h = try await openHarness(foreground: false)
        XCTAssertEqual(h.queue.storageState, .ready)
        let other = try await h.openStore(uid: 2)
        _ = try await other.enqueueIndependentText(
            chatID: "chat", clientGeneratedID: "other", text: "untouched", enqueuedAt: Date())
        let otherOutbox = other.directory.appendingPathComponent("Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: otherOutbox, withIntermediateDirectories: true)
        let otherFile = otherOutbox.appendingPathComponent("owned")
        try Data([1]).write(to: otherFile)

        do {
            try await h.queue.enqueueIndependentText(chatID: "chat", text: "pending")
        } catch {
            return XCTFail("Enqueue before fence: \(error)")
        }
        let pending = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let editor = try h.queue.beginPendingEdit(pendingProjection(pending))
        let image = h.root.appendingPathComponent("image.png")
        try makeMediaPNG(red: 40, green: 30, blue: 20).write(to: image)
        do {
            try await h.queue.importEditAttachments(urls: [image], session: editor, asFiles: false)
        } catch {
            return XCTFail("Editor import before fence: \(error)")
        }
        let imported = try XCTUnwrap(editor.attachments.first)
        do {
            try await h.queue.saveDraft(
                chatID: "chat", text: "draft", editRevision: 1, updatedAt: Date())
        } catch {
            return XCTFail("Draft save before fence: \(error)")
        }
        let current = try await h.openStore(uid: 1)
        let cache = current.directory.appendingPathComponent("unrelated-cache")
        try Data([2]).write(to: cache)

        XCTAssertTrue(h.queue.hasSignOutWork)
        h.queue.fenceForSignOut()
        XCTAssertFalse(editor.isValid)
        h.faults.failures = [.purge]
        do {
            try await h.queue.purgeForSignOut()
            XCTFail("Failed purge must throw")
        } catch QueueTestError.storage {}
        do {
            try await h.queue.saveDraft(
                chatID: "chat", text: "late autosave", editRevision: 2, updatedAt: Date())
            XCTFail("A fenced account must not accept a new write")
        } catch {
            XCTAssertEqual(error as? OutgoingMessageQueue.QueueError, .storageUnavailable)
        }
        let retained = try await current.hasWork()
        XCTAssertTrue(retained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.sourcePath))
        h.faults.failures = []
        do {
            try await h.queue.purgeForSignOut()
            try await h.queue.purgeForSignOut()
        } catch {
            return XCTFail("Purge retry: \(error)")
        }
        let purged = try await current.hasWork()
        let otherRetained = try await other.hasWork()
        XCTAssertFalse(purged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.sourcePath))
        XCTAssertTrue(otherRetained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        await h.queue.deactivate()
        await h.queue.activate(uid: 1)
        XCTAssertFalse(h.queue.hasSignOutWork)
    }

    private func assertDraftContent(
        _ actual: LocalDraft?, _ expected: LocalDraft?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual?.text, expected?.text, file: file, line: line)
        XCTAssertEqual(actual?.replyToMessage, expected?.replyToMessage, file: file, line: line)
        XCTAssertEqual(actual?.attachments, expected?.attachments, file: file, line: line)
        XCTAssertEqual(actual?.linkPreviews, expected?.linkPreviews, file: file, line: line)
        XCTAssertEqual(actual?.updatedAt, expected?.updatedAt, file: file, line: line)
    }

    private func pendingProjection(_ item: LocalOutgoingMessage) -> PendingOutgoingMessage {
        PendingOutgoingMessage(
            chatID: item.chatID, threadID: item.threadID, clientGeneratedID: item.clientGeneratedID,
            body: CreateMessageBody(
                messageType: item.messageType, clientGeneratedId: item.clientGeneratedID,
                message: item.text), enqueuedAt: item.enqueuedAt, senderID: item.senderID,
            phase: .queued(blockedBy: nil), replyToMessage: item.replyToMessage,
            attachments: item.attachments, forwardRequest: item.forwardRequest)
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
        await h.api.finish(0, with: .failure(QueueTestError.rejected))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .pending, .pending]
        }
        return rows
    }

    private func response(_ request: HeldQueueAPI.Request) throws -> MessageResponse {
        let clientID = request.body.clientGeneratedId
        let id = serverIDs[clientID] ?? UInt64(serverIDs.count + 1)
        serverIDs[clientID] = id
        return try TimelineTestFixtures.message(
            id: id, chatID: request.chatID, at: 1,
            type: request.body.messageType, clientGeneratedID: clientID,
            fields: request.threadID.map { ["replyRootId": $0] } ?? [:])
    }

    private func eventually(
        _ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
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

    private func openHarness(
        root: URL? = nil, foreground: Bool = true, failRestore: Bool = false,
        runsWhileInactive: Bool = false,
        retryJitter: @escaping @MainActor () -> Double = { 0 }
    ) async throws -> Harness {
        let harness = try await Harness.open(
            root: root, foreground: foreground, failRestore: failRestore,
            runsWhileInactive: runsWhileInactive,
            retryJitter: retryJitter)
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
    var hold: OutgoingMessageQueue.StorageOperation?
    private var continuation: CheckedContinuation<Void, Never>?
    var isHoldingOperation: Bool { continuation != nil }
    func check(_ operation: OutgoingMessageQueue.StorageOperation) async throws {
        if operation == hold {
            await withCheckedContinuation { continuation = $0 }
        }
        if failures.contains(operation) { throw QueueTestError.storage }
    }

    func release() {
        hold = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor
private final class HeldWriteAuthorization {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class BackgroundAttempts {
    var granted = true
    private(set) var attempts = 0
    var expirations: [@MainActor () -> Void] = []
    private(set) var ended = 0

    func start(_ expire: @escaping @MainActor () -> Void) -> OutboxBackgroundExecution? {
        attempts += 1
        guard granted else { return nil }
        expirations.append(expire)
        return OutboxBackgroundExecution { [weak self] in self?.ended += 1 }
    }
}

@MainActor
private final class Harness {
    let root: URL
    let api = HeldQueueAPI()
    let faults = QueueStorageFaults()
    let background = BackgroundAttempts()
    var queue: OutgoingMessageQueue!
    var invalidTokenStates: [LocalOutgoingMessage.State]?

    private init(
        root: URL, foreground: Bool, runsWhileInactive: Bool,
        retryJitter: @escaping @MainActor () -> Double
    ) {
        self.root = root
        queue = OutgoingMessageQueue(
            apiClient: api,
            storage: AccountLocalStoreOwner { uid in
                try await Task.detached {
                    let scope = LocalStorageScope(
                        apiBaseURL: URL(string: "https://queue.invalid/api")!, userID: uid)
                    return try ChahuaLocalStore(
                        directory: scope.directory(under: root), userID: uid)
                }.value
            },
            onInvalidToken: { [weak self] in
                self?.invalidTokenStates = self?.queue.pendingMessages(chatID: "chat").map(\.state)
            },
            beforeStorageOperation: { [faults] operation in try await faults.check(operation) },
            runsWhileInactive: runsWhileInactive, initiallyForeground: foreground,
            retryJitter: retryJitter,
            startBackgroundExecution: { [background] expire in background.start(expire) },
            uploadFile: { [api] _, _, allocation, _ in
                try await api.holdUpload(allocation.attachmentId)
            }
        )
    }

    static func open(
        root: URL? = nil, foreground: Bool = true, failRestore: Bool = false,
        runsWhileInactive: Bool = false,
        retryJitter: @escaping @MainActor () -> Double
    ) async throws -> Harness {
        let harness = Harness(
            root: root
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                    "OutgoingQueue-\(UUID().uuidString)"),
            foreground: foreground, runsWhileInactive: runsWhileInactive, retryJitter: retryJitter)
        if failRestore { harness.faults.failures = [.restore] }
        await harness.queue.activate(uid: 1)
        return harness
    }

    func openStore(uid: Int32) async throws -> ChahuaLocalStore {
        let root = root
        return try await Task.detached {
            let scope = LocalStorageScope(
                apiBaseURL: URL(string: "https://queue.invalid/api")!, userID: uid)
            return try ChahuaLocalStore(directory: scope.directory(under: root), userID: uid)
        }.value
    }

    func close() async {
        faults.release()
        queue.requestSession(uid: nil)
        await api.finishAll()
        await queue.deactivate()
    }
}

private enum QueueTestError: Error { case rejected, storage, timeout }

private actor HeldQueueAPI: ChahuaAPIClient {
    struct Request: Sendable {
        let chatID: String
        let threadID: String?
        let body: CreateMessageBody
        var singleForward: ForwardMessageBody? = nil
        var mergedForward: ForwardMessagesBody? = nil
        var sourceMessageID: MessageID? = nil
    }

    private var recorded: [Request] = []
    private var held: [Int: CheckedContinuation<MessageResponse, Error>] = [:]
    private var active: [String: Int] = [:]
    private var maximum: [String: Int] = [:]
    private var mutationCalls = 0
    private var uploadsEnabled = false
    private var uploads = 0
    private var heldUploads: [String: CheckedContinuation<Void, Error>] = [:]

    private enum UnexpectedActivityCall: Error { case unread }
    func unreadMentions(chatID: String, threadID: MessageID?) async throws
        -> UnreadMentionIDsResponse
    {
        throw UnexpectedActivityCall.unread
    }
    func unreadReactions(chatID: String, threadID: MessageID?, after: String?) async throws
        -> UnreadReactionIDsResponse
    {
        throw UnexpectedActivityCall.unread
    }
    func acknowledgeReactions(chatID: String, threadID: MessageID?, readThrough: String?)
        async throws -> UnreadReactionsAckResponse
    {
        throw UnexpectedActivityCall.unread
    }

    func readReceipt(chatID: String, threadID: MessageID?) async throws -> ReadReceiptResponse {
        throw APIError.unavailable
    }
    func readReceiptSettings() async throws -> ReadReceiptSettingsResponse {
        throw APIError.unavailable
    }
    func updateReadReceiptSettings(visibility: ReadReceiptVisibility) async throws
        -> ReadReceiptSettingsResponse
    { throw APIError.unavailable }
    func friendReadReceiptSettings(peerUID: Int32) async throws -> FriendReadReceiptSettingsResponse
    {
        throw APIError.unavailable
    }
    func updateFriendReadReceiptSettings(peerUID: Int32, override: FriendReadReceiptOverride)
        async throws -> FriendReadReceiptSettingsResponse
    { throw APIError.unavailable }

    func authenticate(candidateJWT: String) async throws -> MeResponse {
        throw APIError.unavailable
    }
    func createDevSession(uid: Int32, clientID: String) async throws -> String {
        throw APIError.unavailable
    }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func attachmentConfig() async throws -> AttachmentConfigResponse {
        guard uploadsEnabled else { throw APIError.unavailable }
        return AttachmentConfigResponse(maxFileSizeBytes: 1_000_000)
    }
    func requestAttachmentUpload(
        fileName: String, contentType: String, purpose: AttachmentUploadPurpose,
        size: Int64, width: Int, height: Int, order: Int
    ) async throws -> OutgoingUploadAllocation {
        guard uploadsEnabled else { throw APIError.unavailable }
        return OutgoingUploadAllocation(
            attachmentId: "remote-\(order)", uploadURL: URL(string: "https://unused.invalid")!,
            headers: [:])
    }
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
    func createStickerPack(name: String, description: String?) async throws -> StickerPackSummary {
        throw APIError.unavailable
    }
    func updateStickerPack(id: String, name: String?, description: String?) async throws
        -> StickerPackSummary
    { throw APIError.unavailable }
    func deleteStickerPack(id: String) async throws { throw APIError.unavailable }
    func uploadStickerToPack(
        id: String, upload: StickerUpload, emoji: String, name: String?, description: String?
    ) async throws -> MessageStickerResponse { throw APIError.unavailable }
    func removeStickerFromPack(id: String, stickerID: String) async throws {
        throw APIError.unavailable
    }
    func updateStickerPackOrder(_ order: [StickerPackOrderUpdate]) async throws {
        throw APIError.unavailable
    }
    func conversationDifference(cursor: String?) async throws -> ConversationDifference {
        throw APIError.unavailable
    }
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse {
        throw APIError.unavailable
    }
    func archiveChat(chatID: String) async throws { throw APIError.unavailable }
    func unarchiveChat(chatID: String) async throws { throw APIError.unavailable }
    func archiveThread(chatID: String, threadID: String) async throws { throw APIError.unavailable }
    func unarchiveThread(chatID: String, threadID: String) async throws {
        throw APIError.unavailable
    }
    func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse {
        throw APIError.unavailable
    }
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse
    { throw APIError.unavailable }
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
    func getMessage(chatID: String, messageID: MessageID) async throws -> MessageResponse {
        throw APIError.unavailable
    }

    func getReactionDetails(chatID: String, messageID: MessageID) async throws
        -> ReactionDetailResponse
    {
        throw APIError.unavailable
    }
    func deleteMessage(chatID: String, messageID: MessageID) async throws {
        mutationCalls += 1
        throw APIError.unavailable
    }

    func updateMessage(chatID: String, messageID: MessageID, body: UpdateMessageBody) async throws
        -> MessageResponse
    {
        mutationCalls += 1
        throw APIError.unavailable
    }
    func markChatRead(chatID: String, messageID: MessageID) async throws -> ReadStateResponse {
        throw APIError.unavailable
    }
    func markChatUnread(chatID: String) async throws -> ReadStateResponse {
        throw APIError.unavailable
    }
    func markThreadRead(chatID: String, threadID: String, messageID: MessageID) async throws
        -> ReadStateResponse
    { throw APIError.unavailable }
    func putReaction(chatID: String, messageID: MessageID, emoji: String) async throws {
        throw APIError.unavailable
    }
    func deleteReaction(chatID: String, messageID: MessageID, emoji: String) async throws {
        throw APIError.unavailable
    }

    // Intentionally ignores cancellation until explicitly completed, exercising late responses.
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse {
        try await hold(chatID: chatID, threadID: nil, body: body)
    }

    func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody) async throws
        -> MessageResponse
    {
        try await hold(chatID: chatID, threadID: threadID, body: body)
    }

    func forwardMessage(chatID: String, messageID: MessageID, body: ForwardMessageBody)
        async throws -> MessageResponse
    {
        try await hold(
            chatID: chatID, threadID: body.threadId,
            body: CreateMessageBody(messageType: .text, clientGeneratedId: body.clientGeneratedId),
            singleForward: body, sourceMessageID: messageID)
    }

    func forwardMessages(chatID: String, body: ForwardMessagesBody) async throws -> MessageResponse
    {
        try await hold(
            chatID: chatID, threadID: body.threadId,
            body: CreateMessageBody(
                messageType: .forwarded, clientGeneratedId: body.clientGeneratedId),
            mergedForward: body)
    }

    private func hold(
        chatID: String, threadID: String?, body: CreateMessageBody,
        singleForward: ForwardMessageBody? = nil, mergedForward: ForwardMessagesBody? = nil,
        sourceMessageID: MessageID? = nil
    ) async throws -> MessageResponse {
        let index = recorded.count
        recorded.append(
            Request(
                chatID: chatID, threadID: threadID, body: body, singleForward: singleForward,
                mergedForward: mergedForward, sourceMessageID: sourceMessageID))
        active[chatID, default: 0] += 1
        maximum[chatID] = max(maximum[chatID, default: 0], active[chatID, default: 0])
        return try await withCheckedThrowingContinuation { held[index] = $0 }
    }

    func requests() -> [Request] { recorded }
    func maximumConcurrency(chatID: String) -> Int { maximum[chatID, default: 0] }
    func serverMutationCalls() -> Int { mutationCalls }

    func enableUploads() { uploadsEnabled = true }
    func uploadCount() -> Int { uploads }
    func holdUpload(_ id: String) async throws {
        uploads += 1
        try await withCheckedThrowingContinuation { heldUploads[id] = $0 }
    }
    func finishUpload(_ id: String, with result: Result<Void, Error> = .success(())) {
        heldUploads.removeValue(forKey: id)?.resume(with: result)
    }

    func finish(_ index: Int, with result: Result<MessageResponse, Error>) {
        guard let continuation = held.removeValue(forKey: index) else { return }
        active[recorded[index].chatID, default: 0] -= 1
        continuation.resume(with: result)
    }

    func finishAll() {
        for index in Array(held.keys) { finish(index, with: .failure(CancellationError())) }
        for id in Array(heldUploads.keys) { finishUpload(id, with: .failure(CancellationError())) }
    }
}
