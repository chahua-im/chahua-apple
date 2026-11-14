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
        XCTAssertEqual(reopened.queue.snapshots[key]?.draft, draft)
        let pending = PendingOutgoingMessage(
            chatID: "chat", threadID: "thread", clientGeneratedID: restored.clientGeneratedID,
            body: CreateMessageBody(
                messageType: .forwarded, clientGeneratedId: restored.clientGeneratedID),
            enqueuedAt: restored.enqueuedAt, senderID: 1, state: .queued,
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
        XCTAssertEqual(reopened.queue.snapshots[key]?.draft, draft)
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
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat", threadID: "thread").map(\.state) == [
                .failed, .queued,
            ]
        }
        try await h.queue.retry(
            chatID: "chat", threadID: "thread", clientGeneratedID: captured.clientGeneratedID,
            scope: .message)
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
                chatID: "source", senderID: 1, clientGeneratedID: "voice-send",
                attachment: attachment, enqueuedAt: Date())
            // Voice enqueue accepts an imported file; upload completion is a separate checkpoint.
            attachment.attachmentID = "uploaded-voice"
            _ = try await store.checkpointAttachment(
                chatID: "source", itemID: "voice-send", attachment: attachment)
            await h.queue.retryStorage()
            await h.queue.setForegroundActive(true)
            try await eventually { await h.api.requests().count == 1 }
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
                let accepted = await h.queue.acceptAcknowledgement(audio)
                XCTAssertEqual(accepted, .consumed)
            }
            await h.api.finish(0, with: .success(audio))
            await h.queue.setForegroundActive(false)
            if publicationFirst {
                XCTAssertTrue(h.queue.acknowledgedPendingAudioMessages.isEmpty)
                XCTAssertNil(h.queue.forwardPlaceholderReason(for: audio, merging: false))
            } else {
                XCTAssertEqual(h.queue.acknowledgedPendingAudioMessages, [audio])
                XCTAssertEqual(
                    h.queue.forwardPlaceholderReason(for: audio, merging: false), "pendingAudio")
                try await h.queue.enqueueForward(
                    chatID: "chat", sources: [audio], allowPlaceholders: true)
                let pending = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
                let snapshot = try XCTUnwrap(pending.forwardRequest?.sources.first)
                XCTAssertEqual(snapshot.id, audio.id)
                XCTAssertEqual(snapshot.messageType, .placeholder)
                XCTAssertEqual(snapshot.message, "pendingAudio")
                XCTAssertTrue(snapshot.attachments.isEmpty)
                XCTAssertNil(snapshot.sticker)
                h.queue.acceptPublishedForwardSource(audio)
                XCTAssertTrue(h.queue.acknowledgedPendingAudioMessages.isEmpty)
                XCTAssertNil(h.queue.forwardPlaceholderReason(for: audio, merging: false))
                XCTAssertEqual(
                    h.queue.pendingMessages(chatID: "chat").first?.forwardRequest,
                    pending.forwardRequest)
                await h.queue.setForegroundActive(true)
                try await eventually { await h.api.requests().count == 2 }
                let requests = await h.api.requests()
                XCTAssertEqual(requests[1].singleForward?.allowPlaceholders, true)
                XCTAssertEqual(requests[1].sourceMessageID, audio.id)
                await h.api.finish(1, with: .success(try response(requests[1])))
                try await eventually { h.queue.pendingMessages(chatID: "chat").isEmpty }
            }
            await h.queue.activate(uid: 2)
            XCTAssertTrue(h.queue.acknowledgedPendingAudioMessages.isEmpty)
            await h.close()
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
        XCTAssertEqual(reopened.queue.snapshots[thread.conversationKey]?.draft, draft)
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
        await reopened.api.finish(threadIndex, with: .failure(QueueTestError.network))
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
            clientGeneratedID: thread.clientGeneratedID, scope: .message)
        try await eventually { await retried.api.requests().count == 1 }
        let request = try await firstRequest(retried.api)
        XCTAssertEqual(request.threadID, "thread")
        XCTAssertEqual(request.body, requests[threadIndex].body)
        await retried.api.finish(0, with: .success(try response(request)))
        try await eventually {
            retried.queue.pendingMessages(chatID: "chat", threadID: "thread").isEmpty
        }
        XCTAssertEqual(retried.queue.snapshots[thread.conversationKey]?.draft, draft)
    }

    func testStickerSubmissionConsumesOnlyReplyAndPreservesTypedDraftAfterRestart() async throws {
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
        XCTAssertNil(drafts.draftReply(chatID: "chat", threadID: "thread"))
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
        XCTAssertNil(snapshot.draft.replyToMessage)
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
        await h.api.finish(0, with: .failure(QueueTestError.network))
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
            chatID: "chat", threadID: "one", clientGeneratedID: first.body.clientGeneratedId,
            scope: .messageAndSubsequent)
        try await eventually { await h.api.requests().count == 4 }
        let retried = await h.api.requests()
        XCTAssertEqual(retried[3].threadID, "one")
        XCTAssertEqual(retried[3].body.clientGeneratedId, first.body.clientGeneratedId)
        XCTAssertEqual(retried[3].body.message, "reply")
        let accepted = await h.queue.acceptAcknowledgement(try response(retried[3]))
        XCTAssertEqual(accepted, .consumed)
        await h.api.finish(3, with: .failure(QueueTestError.network))
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
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .queued, .queued]
        }
        XCTAssertTrue(transitions.contains([.failed, .queued, .queued]))
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
        for scope in [OutgoingRetryScope.message, .messageAndSubsequent] {
            try await h.queue.retry(
                chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID, scope: scope)
        }
        let pausedRequests = await h.api.requests()
        XCTAssertEqual(pausedRequests.map(\.body.message), ["A"])
        let pending = h.queue.pendingMessages(chatID: "chat")
        XCTAssertEqual(pending.map(\.text), ["A", "B", "C", "D"])
        XCTAssertEqual(pending.map(\.state), [.failed, .queued, .queued, .queued])
        XCTAssertEqual(
            Array(pending.prefix(3)).map(\.clientGeneratedID), rows.map(\.clientGeneratedID))
        try await h.queue.retry(
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID, scope: .message)
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
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID,
            scope: .messageAndSubsequent)
        try await eventually { await h.api.requests().count == 2 }
        for _ in 0..<3 {
            try await h.queue.retry(
                chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID,
                scope: .messageAndSubsequent)
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
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID,
            scope: .messageAndSubsequent)
        try await eventually { await h.api.requests().count == 2 }
        await h.api.finish(1, with: .failure(QueueTestError.network))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .queued, .queued]
        }
        let requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.body.message), ["A", "A"])
        try await h.queue.retry(
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID, scope: .message)
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
        try await h.queue.editOutgoing(
            chatID: "chat", itemID: rows[1].clientGeneratedID,
            expectedRevision: rows[1].editRevision, text: "edited B", attachments: [])
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

    func testSocketFirstAcknowledgementWaitsForHTTPAndLateFailureDoesNotPoisonSuccessor()
        async throws
    {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        let first = try await firstRequest(h.api)
        let message = try response(first)
        let handled = await h.queue.acceptAcknowledgement(message)
        XCTAssertEqual(handled, .consumed)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["B", "C"])
        let stillHeld = await h.api.requests()
        XCTAssertEqual(stillHeld.count, 1)
        let duplicate = await h.queue.acceptAcknowledgement(message)
        XCTAssertEqual(duplicate, .unrelated)
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually { await h.api.requests().count == 2 }
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.sending, .queued])
        await h.close()
        let reopened = try await h.openStore(uid: 1)
        let restored = try await reopened.restore()
        XCTAssertFalse(
            restored.flatMap(\.outgoing).contains {
                $0.clientGeneratedID == message.clientGeneratedId
            })
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

    func testHistoryCanConfirmQueuedWorkWithoutDispatching() async throws {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        let pending = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let message = try TimelineTestFixtures.message(
            id: 1, at: 1, clientGeneratedID: pending.clientGeneratedID)
        let handled = await h.queue.acceptAcknowledgement(message)
        XCTAssertEqual(handled, .consumed)
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
            if case .delivered(_, let message) = $0,
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
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.queued])
        observation.cancel()
        await h.close()
    }

    func testRestartReplaysInterruptedHeadBeforeQueuedSuccessors() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.retry(
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID,
            scope: .messageAndSubsequent)
        try await eventually { await h.api.requests().count == 2 }
        let firstRun = await h.api.requests()
        await h.close()
        let second = try await openHarness(root: h.root)
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
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
        await h.close()

        let restored = try await openHarness(root: h.root)
        XCTAssertEqual(restored.queue.pendingMessages(chatID: "chat").first?.replyToMessage, reply)
        try await restored.queue.retry(
            chatID: "chat", clientGeneratedID: original.body.clientGeneratedId, scope: .message)
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
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.queued])
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
            if case .delivered(_, let response) = $0 { delivered.append(response.id) }
        }
        h.faults.failures = [.acknowledge]
        await h.api.finish(0, with: .success(message))
        try await eventually { h.queue.storageState == .failed && delivered == [message.id] }
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["B", "C"])
        try await h.queue.saveDraft(
            chatID: "chat", text: "new draft", editRevision: 4, updatedAt: Date())
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["B", "C"])
        let paused = await h.api.requests()
        XCTAssertEqual(paused.count, 1)
        h.faults.failures = []
        await h.queue.retryStorage()
        try await eventually { await h.api.requests().count == 2 }
        let resumed = await h.api.requests()
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
    }

    func testFailedFailureCommitIsRetriedAsFailureNotAsAutomaticNetworkRetry() async throws {
        let h = try await openHarness()
        _ = try await enqueueABC(h)
        h.faults.failures = [.fail]
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually { h.queue.storageState == .failed }
        h.faults.failures = []
        await h.queue.retryStorage()
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat").map(\.state), [.failed, .queued, .queued])
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
        XCTAssertEqual(h.invalidTokenStates, [.failed, .queued, .queued])
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
            [.failed, .queued, .queued])
        await reopened.queue.setForegroundActive(false)
        await reopened.queue.setForegroundActive(true)
        let requests = await reopened.api.requests()
        XCTAssertEqual(requests.count, 0)
        try await reopened.queue.retry(
            chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID, scope: .message)
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
        await h.queue.activate(uid: 1)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests[1].body, original.body)
        let concurrency = await h.api.maximumConcurrency(chatID: "chat")
        XCTAssertEqual(concurrency, 2)
        XCTAssertFalse(h.queue.pendingMessages(chatID: "chat").contains { $0.state == .failed })
        await h.api.finish(0, with: .success(try response(original)))
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat").first?.clientGeneratedID,
            original.body.clientGeneratedId)
        await h.close()
    }

    func testRestoredMediaSendUsesSubmissionTimeAndKeepsSenderVisibleThroughAcknowledgement()
        async throws
    {
        let h = try await openHarness(foreground: false)
        let chatStore = ChatStore(apiClient: h.api, outgoingQueue: h.queue, onInvalidToken: {})
        defer { chatStore.cancelRealtimeRecovery() }
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"""
                {"uid": 1, "username": "Ada", "gender": 2, "stickerPackOrder": [], "permissions": []}
                """#.utf8))
        chatStore.currentUserProfile = profile
        // A long-lived caption draft would previously sort between the two
        // earlier outgoing messages, hiding both its sender header and avatar.
        try await h.queue.saveDraft(
            chatID: "chat", text: "Caption", editRevision: 1,
            updatedAt: TimelineTestFixtures.date(second: 1))
        let image = h.root.appendingPathComponent("selected.png")
        try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: image)
        try await h.queue.importImages(urls: [image], chatID: "chat")
        let composition = try XCTUnwrap(
            h.queue.snapshots[ConversationKey(chatID: "chat")]?.composingItem)
        let localStore = try await h.openStore(uid: 1)
        // A history confirmation belongs to an upload-ready create. Preserve the
        // slot's real content generation rather than inventing a frozen payload
        // from a server response for media that was never ready to send.
        var uploaded = try XCTUnwrap(composition.attachments.first)
        uploaded.preparedPath = uploaded.sourcePath
        uploaded.attachmentID = "image"
        _ = try await localStore.checkpointAttachment(
            chatID: "chat", itemID: composition.clientGeneratedID, attachment: uploaded)
        _ = try await localStore.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "unused", text: "Caption",
            enqueuedAt: TimelineTestFixtures.date(second: 4),
            clearedDraftRevision: composition.editRevision + 1)
        await h.queue.retryStorage()

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
                        message.entry.stableKey == .clientGenerated(composition.clientGeneratedID)
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
            clientGeneratedID: composition.clientGeneratedID,
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
        let composition = try XCTUnwrap(h.queue.snapshots[key]?.composingItem)
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
        XCTAssertEqual(discarded.composingItem?.clientGeneratedID, composition.clientGeneratedID)
        XCTAssertEqual(discarded.composingItem?.enqueueSequence, composition.enqueueSequence)
        XCTAssertTrue(discarded.composingItem?.attachments.isEmpty == true)
        await h.close()

        let reopened = try await openHarness(root: h.root, foreground: false)
        let restored = try XCTUnwrap(reopened.queue.snapshots[key])
        XCTAssertEqual(restored.draft, discarded.draft)
        XCTAssertEqual(restored.composingItem, discarded.composingItem)
        XCTAssertEqual(
            reopened.queue.snapshots.mapValues { $0.outgoing.map(\.body) },
            sending.mapValues { $0.map(\.body) })
        let drafts = ChatDraftStore(outgoingQueue: reopened.queue)
        for snapshot in reopened.queue.snapshots.values { drafts.install(snapshot) }
        XCTAssertEqual(drafts.draftText(chatID: "chat", threadID: "thread"), caption)
        XCTAssertTrue(reopened.queue.draftAttachments(chatID: "chat", threadID: "thread").isEmpty)
    }

    func testDiscardDraftAttachmentsPropagatesStaleEditWithoutLosingAttachments() async throws {
        let h = try await openHarness(foreground: false)
        let image = h.root.appendingPathComponent("selected.png")
        try makeMediaPNG(red: 0, green: 255, blue: 0).write(to: image)
        try await h.queue.importImages(urls: [image], chatID: "chat")
        let key = ConversationKey(chatID: "chat")
        let before = try XCTUnwrap(h.queue.snapshots[key])
        let store = try await h.openStore(uid: 1)
        let newer = try await store.saveDraft(
            chatID: "chat", text: "newer caption", editRevision: before.draft.editRevision + 1,
            updatedAt: Date())

        do {
            try await h.queue.discardDraftAttachments(chatID: "chat")
            XCTFail("A stale discard must fail instead of closing with attachments still retained")
        } catch LocalStorageError.staleDraft {}
        XCTAssertEqual(h.queue.draftAttachments(chatID: "chat"), before.draft.attachments)
        let durable = try await store.restore()
        XCTAssertEqual(durable.first?.draft, newer.draft)

        await h.queue.retryStorage()
        try await h.queue.discardDraftAttachments(chatID: "chat")
        XCTAssertTrue(h.queue.draftAttachments(chatID: "chat").isEmpty)
        XCTAssertEqual(h.queue.snapshots[key]?.draft.text, "newer caption")
    }

    func testReorderingCompletedAttachmentsDispatchesExistingIDsInLatestOrder() async throws {
        let h = try await openHarness(foreground: false)
        let store = try await h.openStore(uid: 1)
        let begun = try await store.beginComposition(chatID: "chat", senderID: 1)
        let item = try XCTUnwrap(begun.composingItem)
        let slots = try (0..<2).map { index in
            let file = store.directory.appendingPathComponent("slot-\(index).png")
            try Data([1, 2, 3]).write(to: file, options: .atomic)
            return LocalOutgoingAttachment(
                id: "slot-\(index)", generation: UUID().uuidString, position: index,
                sourcePath: file.path, preparedPath: file.path, previewPath: file.path,
                fileName: file.lastPathComponent, mimeType: "image/png",
                width: 10, height: 10, byteCount: 3, attachmentID: "remote-\(index)")
        }
        _ = try await store.setCompositionAttachments(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            attachments: slots, compressionEnabled: true)
        await h.queue.retryStorage()

        try await h.queue.reorderAttachments(ids: ["slot-1", "slot-0"], chatID: "chat")
        let revision = try XCTUnwrap(
            h.queue.snapshots[ConversationKey(chatID: "chat", threadID: nil)]?.draft.editRevision)
        try await h.queue.enqueueText(chatID: "chat", text: "", clearedDraftRevision: revision + 1)
        await h.queue.setForegroundActive(true)
        // This API cannot allocate uploads: dispatch proves neither completed slot was restarted.
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        XCTAssertEqual(request.body.attachmentIds, ["remote-1", "remote-0"])
        XCTAssertEqual(request.body.clientGeneratedId, item.clientGeneratedID)
    }

    func testClaimedMiddleEditAndRecallOwnDisplayWhileCreateAndPatchResponsesAreHeld() async throws
    {
        let h = try await openHarness()
        let rows = try await enqueueABC(h)
        let first = try await firstRequest(h.api)
        await h.api.finish(0, with: .success(try response(first)))
        try await eventually { await h.api.requests().count == 2 }
        let originalRequests = await h.api.requests()
        let middle = originalRequests[1]
        try await h.queue.saveDraft(
            chatID: "chat", text: "ordinary", editRevision: 20, updatedAt: Date())
        let claimed = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        try await h.queue.editOutgoing(
            chatID: "chat", itemID: claimed.clientGeneratedID,
            expectedRevision: claimed.editRevision, text: "latest B", attachments: [])
        let created = try response(middle)
        let disposition = await h.queue.acceptAcknowledgement(created)
        XCTAssertEqual(disposition, .suppress)
        try await eventually { await h.api.patchRequests().count == 1 }
        let patches = await h.api.patchRequests()
        XCTAssertEqual(patches[0].body.message, "latest B")
        XCTAssertEqual(patches[0].body.attachmentIds, [])
        XCTAssertEqual(middle.body.message, "B")
        XCTAssertEqual(middle.body.clientGeneratedId, rows[1].clientGeneratedID)
        let latest = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        try await h.queue.cancelOutgoing(
            chatID: "chat", itemID: latest.clientGeneratedID, expectedRevision: latest.editRevision)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["C"])
        let beforePatchCompletion = await h.api.deleteRequests()
        XCTAssertTrue(beforePatchCompletion.isEmpty)
        await h.api.finishPatch(
            0,
            with: .success(
                try patchResponse(
                    patches[0], clientID: middle.body.clientGeneratedId)))
        try await eventually { await h.api.deleteRequests().count == 1 }
        await h.api.finishDelete(0, with: .success(()))
        try await eventually {
            h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing
                .contains(where: { $0.clientGeneratedID == latest.clientGeneratedID }) == false
        }
        let history = await h.queue.acceptAcknowledgement(created)
        XCTAssertEqual(history, .suppress)
        await h.api.finish(1, with: .success(created))
        try await eventually { await h.api.requests().count == 3 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests[2].body.clientGeneratedId, rows[2].clientGeneratedID)
        XCTAssertEqual(h.queue.snapshots[ConversationKey(chatID: "chat")]?.draft.text, "ordinary")
    }

    func testUnknownCancelledCreateNeverRepostsAndDoesNotBlockSuccessorAfterFailure() async throws {
        let h = try await openHarness()
        let rows = try await enqueueABC(h)
        try await h.queue.cancelOutgoing(
            chatID: "chat", itemID: rows[0].clientGeneratedID,
            expectedRevision: rows[0].editRevision)
        await h.api.finish(0, with: .failure(APIError.transport(URLError(.networkConnectionLost))))
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests[1].body.clientGeneratedId, rows[1].clientGeneratedID)
        XCTAssertFalse(
            h.queue.pendingMessages(chatID: "chat").contains {
                $0.clientGeneratedID == rows[0].clientGeneratedID
            })
        await h.close()
        let reopened = try await openHarness(root: h.root)
        try await eventually { await reopened.api.requests().count == 1 }
        let resumed = await reopened.api.requests()
        XCTAssertEqual(resumed[0].body.clientGeneratedId, rows[1].clientGeneratedID)
        XCTAssertFalse(resumed.contains { $0.body.clientGeneratedId == rows[0].clientGeneratedID })
        let tombstone = try XCTUnwrap(
            reopened.queue.snapshots[ConversationKey(chatID: "chat")]?
                .outgoing.first { $0.clientGeneratedID == rows[0].clientGeneratedID })
        XCTAssertTrue(tombstone.isCancelled)
        XCTAssertNil(tombstone.confirmedMessage)
    }

    func testFrozenCreateReplaysOriginalPayloadAfterSubmittedEditAndSceneInterruption() async throws
    {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let original = try await firstRequestAfterDispatch(h)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        try await h.queue.editOutgoing(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            text: "replacement", attachments: [])
        h.queue.requestForegroundActive(false)
        await h.api.finish(0, with: .failure(CancellationError()))
        await h.queue.setForegroundActive(false)
        await h.queue.setForegroundActive(true)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests[1].body, original.body)
        await h.api.finish(1, with: .success(try response(original)))
        try await eventually { await h.api.patchRequests().count == 1 }
        let patches = await h.api.patchRequests()
        XCTAssertEqual(patches[0].body.message, "replacement")
    }

    func testTransientPatchReplaysClaimThenNewerIntentAndPermanentFailureNeedsExplicitRetry()
        async throws
    {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let request = try await firstRequestAfterDispatch(h)
        let original = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        try await h.queue.editOutgoing(
            chatID: "chat", itemID: original.clientGeneratedID,
            expectedRevision: original.editRevision,
            text: "first edit", attachments: [])
        await h.api.finish(0, with: .success(try response(request)))
        try await eventually { await h.api.patchRequests().count == 1 }
        await h.api.finishPatch(0, with: .failure(APIError.http(status: 503, body: Data())))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").first?.mutationRetryable == true
        }
        try await eventually { await h.api.patchRequests().count == 2 }
        var patches = await h.api.patchRequests()
        XCTAssertEqual(patches[0].body, patches[1].body)
        await h.api.finishPatch(1, with: .failure(APIError.http(status: 403, body: Data())))
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
        await h.queue.setForegroundActive(false)
        await h.queue.setForegroundActive(true)
        let afterReconnect = await h.api.patchRequests()
        XCTAssertEqual(afterReconnect.count, 2)
        let failed = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        XCTAssertFalse(failed.mutationRetryable)
        try await h.queue.editOutgoing(
            chatID: "chat", itemID: failed.clientGeneratedID, expectedRevision: failed.editRevision,
            text: "newer edit", attachments: [])
        try await eventually { await h.api.patchRequests().count == 3 }
        patches = await h.api.patchRequests()
        XCTAssertEqual(patches[2].body.message, "first edit")
        await h.api.finishPatch(
            2,
            with: .success(
                try patchResponse(
                    patches[2], clientID: original.clientGeneratedID)))
        try await eventually { await h.api.patchRequests().count == 4 }
        patches = await h.api.patchRequests()
        XCTAssertEqual(patches[3].body.message, "newer edit")
        await h.api.finishPatch(3, with: .failure(APIError.http(status: 400, body: Data())))
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
        try await h.queue.retry(
            chatID: "chat", clientGeneratedID: original.clientGeneratedID, scope: .message)
        try await eventually { await h.api.patchRequests().count == 5 }
        patches = await h.api.patchRequests()
        XCTAssertEqual(patches[4].body.message, "newer edit")
    }

    func testFailedRecallStaysHiddenAndExplicitRetryAcceptsNotFound() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "secret", clearedDraftRevision: 1)
        let request = try await firstRequestAfterDispatch(h)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        try await h.queue.cancelOutgoing(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision)
        await h.api.finish(0, with: .success(try response(request)))
        try await eventually { await h.api.deleteRequests().count == 1 }
        await h.api.finishDelete(0, with: .failure(APIError.http(status: 403, body: Data())))
        try await eventually {
            h.queue.failedCancellationIDs(chatID: "chat") == [item.clientGeneratedID]
        }
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        await h.queue.setForegroundActive(false)
        await h.queue.setForegroundActive(true)
        let beforeRetry = await h.api.deleteRequests()
        XCTAssertEqual(beforeRetry.count, 1)
        try await h.queue.retry(
            chatID: "chat", clientGeneratedID: item.clientGeneratedID, scope: .message)
        try await eventually { await h.api.deleteRequests().count == 2 }
        await h.api.finishDelete(1, with: .failure(APIError.http(status: 404, body: Data())))
        try await eventually {
            h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing.isEmpty == true
        }
        XCTAssertTrue(h.queue.failedCancellationIDs(chatID: "chat").isEmpty)
        let disposition = await h.queue.acceptAcknowledgement(try response(request))
        XCTAssertEqual(disposition, .suppress)
    }

    func testAudioRecallWaitsForActualPublicationAndForegroundRead() async throws {
        try await assertAudioRecallPublication(useResync: false)
    }

    func testAudioRecallWaitsForActualPublicationAndResyncRead() async throws {
        try await assertAudioRecallPublication(useResync: true)
    }

    private func assertAudioRecallPublication(useResync: Bool) async throws {
        let h = try await openHarness(foreground: false)
        let voice = h.root.appendingPathComponent("voice.m4a")
        try Data([0, 0, 0, 12] + Array("ftyp".utf8) + [0, 0, 0, 0]).write(to: voice)
        try await h.queue.enqueueVoice(chatID: "chat", fileURL: voice)
        let store = try await h.openStore(uid: 1)
        let pending = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        var slot = try XCTUnwrap(pending.attachments.first)
        slot.attachmentID = "voice-remote"
        _ = try await store.checkpointAttachment(
            chatID: "chat", itemID: pending.clientGeneratedID, attachment: slot)
        await h.queue.retryStorage()
        await h.queue.setForegroundActive(true)
        let request = try await firstRequestAfterDispatch(h)
        let audio = try response(request)
        try await h.queue.cancelOutgoing(
            chatID: "chat", itemID: pending.clientGeneratedID,
            expectedRevision: pending.editRevision)
        await h.api.finish(0, with: .success(audio))
        try await eventually { await h.api.readRequests().count == 1 }
        let unpublishedDeletes = await h.api.deleteRequests()
        XCTAssertTrue(unpublishedDeletes.isEmpty)
        await h.api.setReadResponse(audio)
        if useResync {
            h.queue.resynchronizePublications()
        } else {
            await h.queue.setForegroundActive(false)
            await h.queue.setForegroundActive(true)
        }
        try await eventually { await h.api.deleteRequests().count == 1 }
        let creates = await h.api.requests()
        XCTAssertEqual(creates.count, 1)
    }

    func testPendingLeaseRegisteredBeforeSuspensionSurvivesConfirmationAndSubmitsSameIdentity()
        async throws
    {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        var authorization: CheckedContinuation<Void, Never>?
        h.queue.authorizeWrite = { _, _ in
            await withCheckedContinuation { authorization = $0 }
        }
        let beginning = Task { try await h.queue.beginPendingEdit(self.pendingProjection(item)) }
        try await eventually { authorization != nil }
        let confirmation = try TimelineTestFixtures.message(
            id: 80, at: 1, clientGeneratedID: item.clientGeneratedID)
        let disposition = await h.queue.acceptAcknowledgement(confirmation)
        XCTAssertEqual(disposition, .consumed)
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        XCTAssertEqual(h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing.count, 1)
        h.queue.authorizeWrite = nil
        authorization?.resume()
        let session = try await beginning.value
        XCTAssertTrue(session.isValid)
        try await h.queue.submitPendingEdit(session, text: "edited after delivery")
        XCTAssertFalse(session.isValid)
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat").first?.clientGeneratedID,
            item.clientGeneratedID)
        await h.queue.setForegroundActive(true)
        try await eventually { await h.api.patchRequests().count == 1 }
        let creates = await h.api.requests()
        XCTAssertTrue(creates.isEmpty)
    }

    func testEditorStaleSubmitAndStorageFailureKeepContentButCancellationInvalidatesLease()
        async throws
    {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let first = try await h.queue.beginPendingEdit(pendingProjection(item))
        let second = try await h.queue.beginPendingEdit(pendingProjection(item))
        h.faults.failures = [.edit]
        do {
            try await h.queue.submitPendingEdit(first, text: "changed")
            XCTFail("Expected durable edit failure")
        } catch {}
        XCTAssertTrue(first.isValid)
        XCTAssertNotNil(first.error)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.text, "original")
        h.faults.failures = []
        try await h.queue.submitPendingEdit(first, text: "changed")
        do {
            try await h.queue.submitPendingEdit(second, text: "stale change")
            XCTFail("Expected stale revision")
        } catch {}
        XCTAssertTrue(second.isValid)
        XCTAssertNotNil(second.error)
        let latest = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        h.faults.failures = [.cancel]
        do {
            try await h.queue.cancelOutgoing(
                chatID: "chat", itemID: latest.clientGeneratedID,
                expectedRevision: latest.editRevision)
            XCTFail("Expected durable cancellation failure")
        } catch {}
        XCTAssertTrue(second.isValid)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.text, "changed")
        h.faults.failures = []
        try await h.queue.cancelOutgoing(
            chatID: "chat", itemID: latest.clientGeneratedID, expectedRevision: latest.editRevision)
        XCTAssertFalse(second.isValid)
    }

    func testCancelEditorReleasesOnlyNewImportsAndSubmitTransfersSelectedImports() async throws {
        let h = try await openHarness(foreground: false)
        let image = h.root.appendingPathComponent("image.png")
        try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: image)
        try await h.queue.importImages(urls: [image], chatID: "chat")
        try await h.queue.enqueueText(chatID: "chat", text: "caption", clearedDraftRevision: 2)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let borrowed = try XCTUnwrap(item.attachments.first)
        let session = try await h.queue.beginPendingEdit(pendingProjection(item))
        try await h.queue.importEditImages(urls: [image], session: session)
        guard case .local(let imported) = try XCTUnwrap(session.attachments.last) else {
            return XCTFail("Expected a local import")
        }
        h.queue.removeEditAttachment(id: borrowed.id, session: session)
        h.queue.endPendingEdit(session)
        try await eventually { !FileManager.default.fileExists(atPath: imported.sourcePath) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: borrowed.sourcePath))
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.attachments, [borrowed])
        let replacement = try await h.queue.beginPendingEdit(pendingProjection(item))
        try await h.queue.importEditImages(urls: [image], session: replacement)
        guard case .local(let committed) = try XCTUnwrap(replacement.attachments.last) else {
            return XCTFail("Expected a second local import")
        }
        h.queue.removeEditAttachment(id: borrowed.id, session: replacement)
        try await h.queue.submitPendingEdit(replacement, text: "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.sourcePath))
        XCTAssertFalse(replacement.isValid)
        await h.close()
        let reopened = try await openHarness(root: h.root, foreground: false)
        let selection = try XCTUnwrap(
            reopened.queue.pendingMessages(chatID: "chat").first?
                .intentAttachments)
        XCTAssertEqual(selection.count, 1)
        guard case .local(let restored) = selection[0] else {
            return XCTFail("Expected local intent")
        }
        XCTAssertEqual(restored.sourcePath, committed.sourcePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.sourcePath))
    }

    func testPendingEditPersistsMetadataOnlyChangeAndSeedsNextEditor() async throws {
        let h = try await openHarness(foreground: false)
        let text = "https://example.com"
        try await h.queue.enqueueText(chatID: "chat", text: text, clearedDraftRevision: 1)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let session = try await h.queue.beginPendingEdit(pendingProjection(item))
        let metadata = MessageMetadataInput(
            linkPreviews: [.init(url: text, status: .disabled)])
        XCTAssertFalse(session.hasChanges(text: text))
        XCTAssertTrue(session.hasChanges(text: text, metadata: metadata))
        try await h.queue.submitPendingEdit(session, text: text, metadata: metadata)
        let changed = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        XCTAssertEqual(changed.text, text)
        XCTAssertEqual(changed.metadata, metadata)
        XCTAssertEqual(changed.editRevision, item.editRevision + 1)
        let next = try await h.queue.beginPendingEdit(pendingProjection(changed))
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
        let session = try await h.queue.beginPendingEdit(pendingProjection(item))
        XCTAssertFalse(session.hasChanges(text: " \ncaption\n "))
        do {
            try await h.queue.importEditImages(
                urls: Array(repeating: h.root.appendingPathComponent("unused.png"), count: 21),
                session: session)
            XCTFail("Expected attachment limit")
        } catch LocalStorageError.invalidAttachments {}
        XCTAssertTrue(session.attachments.isEmpty)
        XCTAssertTrue(session.isValid)
        do {
            try await h.queue.submitPendingEdit(session, text: "  caption  ")
            XCTFail("Expected unchanged edit rejection")
        } catch {}
        XCTAssertTrue(session.isValid)
        await h.queue.activate(uid: 2)
        XCTAssertFalse(session.isValid)
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
    }

    func testPatchStorageRecoveryDoesNotRepeatKnownSuccessfulMutation() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let request = try await firstRequestAfterDispatch(h)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        try await h.queue.editOutgoing(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            text: "edited", attachments: [])
        await h.api.finish(0, with: .success(try response(request)))
        try await eventually { await h.api.patchRequests().count == 1 }
        let patches = await h.api.patchRequests()
        h.faults.failures = [.acknowledge]
        await h.api.finishPatch(
            0,
            with: .success(
                try patchResponse(
                    patches[0], clientID: item.clientGeneratedID)))
        try await eventually { h.queue.storageState == .failed }
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.text, "edited")
        h.faults.failures = []
        await h.queue.retryStorage()
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        let afterRecovery = await h.api.patchRequests()
        XCTAssertEqual(afterRecovery.count, 1)
        let creates = await h.api.requests()
        XCTAssertEqual(creates.count, 1)
    }

    func testRealtimePatchConfirmationWinsHeldHTTPFailureAndLateCreateBody() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let request = try await firstRequestAfterDispatch(h)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        var observed: [String?] = []
        let observation = h.queue.events.sink {
            switch $0 {
            case .delivered(_, let message), .updated(_, let message):
                observed.append(message.message)
            default: break
            }
        }
        try await h.queue.editOutgoing(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            text: "edited", attachments: [])
        let created = try response(request)
        _ = await h.queue.acceptAcknowledgement(created)
        try await eventually { await h.api.patchRequests().count == 1 }
        let patches = await h.api.patchRequests()
        let patched = try patchResponse(patches[0], clientID: item.clientGeneratedID)
        let disposition = await h.queue.acceptAcknowledgement(patched)
        XCTAssertEqual(disposition, .consumed)
        XCTAssertEqual(observed, ["edited"])
        await h.api.finishPatch(0, with: .failure(APIError.invalidToken))
        await h.api.finish(0, with: .success(created))
        try await eventually {
            h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing.isEmpty == true
        }
        XCTAssertTrue(observed.allSatisfy { $0 == "edited" })
        XCTAssertNil(h.invalidTokenStates)
        observation.cancel()
    }

    func testServerMediaReorderSubmitsMediaOnlyEditWithoutReuploadOrChangedBaseline() async throws {
        let h = try await openHarness(foreground: false)
        let image = h.root.appendingPathComponent("image.png")
        try makeMediaPNG(red: 0, green: 255, blue: 0).write(to: image)
        try await h.queue.importImages(urls: [image, image], chatID: "chat")
        let store = try await h.openStore(uid: 1)
        let composition = try XCTUnwrap(
            h.queue.snapshots[ConversationKey(chatID: "chat")]?.composingItem)
        for (index, original) in composition.attachments.enumerated() {
            var slot = original
            slot.preparedPath = slot.sourcePath
            slot.attachmentID = "uploaded-\(index)"
            _ = try await store.checkpointAttachment(
                chatID: "chat", itemID: composition.clientGeneratedID, attachment: slot)
        }
        await h.queue.retryStorage()
        try await h.queue.enqueueText(chatID: "chat", text: "", clearedDraftRevision: 4)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let session = try await h.queue.beginPendingEdit(pendingProjection(item))
        await h.queue.setForegroundActive(true)
        let request = try await firstRequestAfterDispatch(h)
        let serverAttachments: [[String: Any]] = (0..<2).map {
            [
                "id": "uploaded-\($0)", "url": "https://example.invalid/\($0).png",
                "kind": "image/png", "size": 1, "fileName": "\($0).png",
            ]
        }
        let created = try TimelineTestFixtures.message(
            id: 95, at: 1, text: "", clientGeneratedID: item.clientGeneratedID,
            fields: ["attachments": serverAttachments])
        await h.api.finish(0, with: .success(created))
        try await eventually {
            h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing.first?.confirmedMessage
                != nil
        }
        XCTAssertFalse(session.hasChanges(text: "  "))
        XCTAssertFalse(session.isUploading)
        XCTAssertEqual(
            session.attachments.compactMap {
                if case .server(let value) = $0 { value.id } else { nil }
            }, ["uploaded-0", "uploaded-1"])
        try h.queue.reorderEditAttachments(ids: ["uploaded-1", "uploaded-0"], session: session)
        XCTAssertTrue(session.hasChanges(text: ""))
        try await h.queue.submitPendingEdit(session, text: "")
        try await eventually { await h.api.patchRequests().count == 1 }
        let patches = await h.api.patchRequests()
        XCTAssertEqual(patches[0].body.message, "")
        XCTAssertEqual(patches[0].body.attachmentIds, ["uploaded-1", "uploaded-0"])
        XCTAssertEqual(request.body.attachmentIds, ["uploaded-0", "uploaded-1"])
        let creates = await h.api.requests()
        XCTAssertEqual(creates.count, 1)
    }

    func testAuthoritativeDeletionInvalidatesOpenEditorAndStorageRecoveryNeverResurrectsIt()
        async throws
    {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let session = try await h.queue.beginPendingEdit(pendingProjection(item))
        let deleted = try TimelineTestFixtures.message(
            id: 98, at: 1, clientGeneratedID: item.clientGeneratedID
        ).redactedForDeletion()
        h.faults.failures = [.delete]
        let disposition = await h.queue.acceptDeletion(deleted)
        XCTAssertEqual(disposition, .consumed)
        XCTAssertFalse(session.isValid)
        XCTAssertEqual(h.queue.storageState, .failed)
        let oldCreate = try TimelineTestFixtures.message(
            id: 98, at: 1, clientGeneratedID: item.clientGeneratedID)
        let suppressed = await h.queue.acceptAcknowledgement(oldCreate)
        XCTAssertEqual(suppressed, .suppress)
        h.faults.failures = []
        await h.queue.retryStorage()
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        XCTAssertEqual(h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing, [])
        let requests = await h.api.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testLastEditorLeaseReleaseAndRestartFinalizeCleanConfirmedRows() async throws {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let first = try await h.queue.beginPendingEdit(pendingProjection(item))
        let second = try await h.queue.beginPendingEdit(pendingProjection(item))
        let confirmation = try TimelineTestFixtures.message(
            id: 99, at: 1, clientGeneratedID: item.clientGeneratedID)
        _ = await h.queue.acceptAcknowledgement(confirmation)
        h.queue.endPendingEdit(first)
        XCTAssertEqual(h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing.count, 1)
        h.queue.endPendingEdit(second)
        try await eventually {
            h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing.isEmpty == true
        }
        try await h.queue.enqueueText(chatID: "chat", text: "restart", clearedDraftRevision: 2)
        let restartItem = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        _ = try await h.queue.beginPendingEdit(pendingProjection(restartItem))
        _ = await h.queue.acceptAcknowledgement(
            try TimelineTestFixtures.message(
                id: 100, at: 1, clientGeneratedID: restartItem.clientGeneratedID))
        XCTAssertEqual(h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing.count, 1)
        await h.close()
        let reopened = try await openHarness(root: h.root, foreground: false)
        XCTAssertTrue(reopened.queue.pendingMessages(chatID: "chat").isEmpty)
        XCTAssertEqual(reopened.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing, [])
    }

    func testMutationFailureStorageRecoveryPreservesPermanentFailureWithoutNetworkReplay()
        async throws
    {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let request = try await firstRequestAfterDispatch(h)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        try await h.queue.editOutgoing(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision,
            text: "edited", attachments: [])
        await h.api.finish(0, with: .success(try response(request)))
        try await eventually { await h.api.patchRequests().count == 1 }
        h.faults.failures = [.fail]
        await h.api.finishPatch(0, with: .failure(APIError.http(status: 403, body: Data())))
        try await eventually { h.queue.storageState == .failed }
        h.faults.failures = []
        await h.queue.retryStorage()
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.state, .failed)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").first?.mutationRetryable, false)
        let patches = await h.api.patchRequests()
        XCTAssertEqual(patches.count, 1)
    }

    func testSpeakingRestrictionDoesNotPreventRecallingOwnedPendingMessage() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let request = try await firstRequestAfterDispatch(h)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        h.queue.authorizeWrite = { _, _ in throw APIError.http(status: 403, body: Data()) }
        try await h.queue.cancelOutgoing(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision)
        await h.api.finish(0, with: .success(try response(request)))
        try await eventually { await h.api.deleteRequests().count == 1 }
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        let patches = await h.api.patchRequests()
        XCTAssertTrue(patches.isEmpty)
    }

    func testMutationWorkersAreIndependentForDifferentItemsInSameConversation() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        let firstRequest = try await firstRequestAfterDispatch(h)
        let first = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        try await h.queue.editOutgoing(
            chatID: "chat", itemID: first.clientGeneratedID, expectedRevision: first.editRevision,
            text: "edit A", attachments: [])
        let firstConfirmation = try response(firstRequest)
        _ = await h.queue.acceptAcknowledgement(firstConfirmation)
        try await eventually { await h.api.patchRequests().count == 1 }
        try await h.queue.enqueueText(chatID: "chat", text: "B", clearedDraftRevision: 2)
        await h.api.finish(0, with: .success(firstConfirmation))
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        let second = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").last)
        try await h.queue.editOutgoing(
            chatID: "chat", itemID: second.clientGeneratedID, expectedRevision: second.editRevision,
            text: "edit B", attachments: [])
        _ = await h.queue.acceptAcknowledgement(try response(requests[1]))
        try await eventually { await h.api.patchRequests().count == 2 }
        let patches = await h.api.patchRequests()
        XCTAssertEqual(patches.map(\.body.message), ["edit A", "edit B"])
        XCTAssertNotEqual(patches[0].messageID, patches[1].messageID)
        let heldCreates = await h.api.requests()
        XCTAssertEqual(heldCreates.count, 2)
    }

    func testAccountReplacementDoesNotWaitForHeldPatchAndReopenReplaysOnlyItsAccount()
        async throws
    {
        let h = try await openHarness()
        try await h.queue.enqueueText(
            chatID: "chat", threadID: "root", text: "account one", clearedDraftRevision: 1)
        let request = try await firstRequestAfterDispatch(h)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat", threadID: "root").first)
        try await h.queue.editOutgoing(
            chatID: "chat", threadID: "root", itemID: item.clientGeneratedID,
            expectedRevision: item.editRevision, text: "account one edit", attachments: [])
        await h.api.finish(0, with: .success(try response(request)))
        try await eventually { await h.api.patchRequests().count == 1 }
        let originalPatches = await h.api.patchRequests()
        await h.queue.activate(uid: 2)
        XCTAssertEqual(h.queue.storageState, .ready)
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat", threadID: "root").isEmpty)
        try await h.queue.enqueueText(
            chatID: "chat", threadID: "root", text: "account two", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 2 }
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat", threadID: "root").first?.senderID, 2)
        await h.api.finishPatch(
            0,
            with: .success(
                try patchResponse(
                    originalPatches[0], clientID: item.clientGeneratedID)))
        XCTAssertEqual(
            h.queue.pendingMessages(chatID: "chat", threadID: "root").map(\.text),
            ["account two"])
        await h.queue.activate(uid: 1)
        try await eventually { await h.api.patchRequests().count == 2 }
        let replayed = await h.api.patchRequests()
        XCTAssertEqual(replayed[1].body, originalPatches[0].body)
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat", threadID: "root").first?.senderID, 1)
    }

    func testEditorUsesSharedUploadBoundAndDeselectionDoesNotCancelBorrowedUpload() async throws {
        let h = try await openHarness(foreground: false)
        let image = h.root.appendingPathComponent("image.png")
        try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: image)
        try await h.queue.importImages(urls: [image], chatID: "chat")
        try await h.queue.enqueueText(chatID: "chat", text: "caption", clearedDraftRevision: 2)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let borrowed = try XCTUnwrap(item.attachments.first)
        let session = try await h.queue.beginPendingEdit(pendingProjection(item))
        h.queue.removeEditAttachment(id: borrowed.id, session: session)
        try await h.queue.importEditImages(urls: [image, image, image], session: session)
        let importedPaths = session.attachments.compactMap { selection -> String? in
            if case .local(let slot) = selection { return slot.sourcePath }
            return nil
        }
        await h.api.holdAttachmentConfigurations()
        await h.queue.setForegroundActive(true)
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").first?.attachments.first?.preparedPath != nil
                && session.attachments.allSatisfy {
                    if case .local(let slot) = $0 { return slot.preparedPath != nil }
                    return false
                }
        }
        try await eventually { await h.api.attachmentConfigurationCount() == 2 }
        h.queue.endPendingEdit(session)
        await h.api.finishAttachmentConfiguration(
            0, with: .failure(APIError.http(status: 503, body: Data())))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").first?.attachments.first?.error != nil
        }
        await h.api.finishAttachmentConfiguration(1, with: .failure(CancellationError()))
        try await eventually {
            importedPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: borrowed.sourcePath))
        let count = await h.api.attachmentConfigurationCount()
        XCTAssertEqual(count, 2)
    }

    func testDeletionAfterCleanFinalizationSuppressesHeldCreateSuccessAndOldHistory() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let request = try await firstRequestAfterDispatch(h)
        let created = try response(request)
        var deliveries = 0
        let observation = h.queue.events.sink {
            if case .delivered = $0 { deliveries += 1 }
        }
        _ = await h.queue.acceptAcknowledgement(created)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing, [])
        let deletion = await h.queue.acceptDeletion(created.redactedForDeletion())
        XCTAssertEqual(deletion, .unrelated)
        let history = await h.queue.acceptAcknowledgement(created)
        XCTAssertEqual(history, .suppress)
        try await h.queue.enqueueText(chatID: "chat", text: "successor", clearedDraftRevision: 2)
        await h.api.finish(0, with: .success(created))
        try await eventually { await h.api.requests().count == 2 }
        XCTAssertEqual(deliveries, 1)
        observation.cancel()
    }

    func testTransientRecallFailureRestoresAsDeleteWithoutRecreatingMessage() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "original", clearedDraftRevision: 1)
        let request = try await firstRequestAfterDispatch(h)
        let item = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        try await h.queue.cancelOutgoing(
            chatID: "chat", itemID: item.clientGeneratedID, expectedRevision: item.editRevision)
        await h.api.finish(0, with: .success(try response(request)))
        try await eventually { await h.api.deleteRequests().count == 1 }
        await h.api.finishDelete(0, with: .failure(APIError.http(status: 429, body: Data())))
        try await eventually {
            h.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing.first?.mutationRetryable
                == true
        }
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        await h.close()
        let reopened = try await openHarness(root: h.root)
        try await eventually { await reopened.api.deleteRequests().count == 1 }
        let creates = await reopened.api.requests()
        XCTAssertTrue(creates.isEmpty)
        let deletes = await reopened.api.deleteRequests()
        XCTAssertEqual(deletes[0].messageID, try response(request).id)
        await reopened.api.finishDelete(0, with: .failure(APIError.http(status: 410, body: Data())))
        try await eventually {
            reopened.queue.snapshots[ConversationKey(chatID: "chat")]?.outgoing.isEmpty == true
        }
    }

    func testAccountRetirementDrainsKnownResponseStorageButNotHeldTransport() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "delivered", text: "A", clearedDraftRevision: 1)
        try await h.queue.enqueueText(chatID: "held", text: "B", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        let deliveredIndex = try XCTUnwrap(requests.firstIndex { $0.chatID == "delivered" })
        let heldIndex = try XCTUnwrap(requests.firstIndex { $0.chatID == "held" })
        h.faults.hold = .acknowledge
        await h.api.finish(deliveredIndex, with: .success(try response(requests[deliveredIndex])))
        try await eventually { h.faults.isHoldingOperation }

        let prematureRetirement = expectation(
            description: "SQLite retirement waits for local commit")
        prematureRetirement.isInverted = true
        var releasedCommit = false
        let retiring = Task {
            await h.queue.deactivate()
            if !releasedCommit { prematureRetirement.fulfill() }
        }
        await fulfillment(of: [prematureRetirement], timeout: 0.05)
        XCTAssertEqual(h.queue.storageState, .inactive)
        releasedCommit = true
        h.faults.release()
        // B still ignores transport cancellation. It must not delay account retirement.
        await retiring.value

        let reopened = try await openHarness(root: h.root, foreground: false)
        XCTAssertEqual(reopened.queue.storageState, .ready)
        XCTAssertTrue(reopened.queue.pendingMessages(chatID: "delivered").isEmpty)
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "held").map(\.text), ["B"])
        await h.api.finish(heldIndex, with: .success(try response(requests[heldIndex])))
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "held").map(\.text), ["B"])
    }

    private func firstRequestAfterDispatch(_ h: Harness) async throws -> HeldQueueAPI.Request {
        try await eventually { await h.api.requests().count >= 1 }
        return try await firstRequest(h.api)
    }

    private func pendingProjection(_ item: LocalOutgoingMessage) -> PendingOutgoingMessage {
        PendingOutgoingMessage(
            chatID: item.chatID, threadID: item.threadID, clientGeneratedID: item.clientGeneratedID,
            body: CreateMessageBody(
                messageType: item.messageType, clientGeneratedId: item.clientGeneratedID,
                message: item.text), enqueuedAt: item.enqueuedAt, senderID: item.senderID,
            state: .queued, replyToMessage: item.replyToMessage, attachments: item.attachments,
            dispatchClaimed: item.dispatchClaimed, editRevision: item.editRevision,
            forwardRequest: item.forwardRequest, intentAttachments: item.intentAttachments)
    }

    private func patchResponse(_ request: HeldQueueAPI.PatchRequest, clientID: String) throws
        -> MessageResponse
    {
        try TimelineTestFixtures.message(
            id: request.messageID.rawValue, chatID: request.chatID, at: 2,
            text: request.body.message, clientGeneratedID: clientID,
            fields: [
                "attachments": (request.body.attachmentIds ?? []).map { id -> [String: Any] in
                    [
                        "id": id, "url": "https://example.invalid/\(id)", "kind": "image/png",
                        "size": 1, "fileName": "\(id).png",
                    ]
                }
            ])
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
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .queued, .queued]
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

    private func openHarness(root: URL? = nil, foreground: Bool = true, failRestore: Bool = false)
        async throws -> Harness
    {
        let harness = try await Harness.open(
            root: root, foreground: foreground, failRestore: failRestore)
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
                    let scope = LocalStorageScope(
                        apiBaseURL: URL(string: "https://queue.invalid/api")!, userID: uid)
                    return try ChahuaLocalStore(directory: scope.directory(under: root))
                }.value
            },
            onInvalidToken: { [weak self] in
                self?.invalidTokenStates = self?.queue.pendingMessages(chatID: "chat").map(\.state)
            },
            beforeStorageOperation: { [faults] operation in try await faults.check(operation) }
        )
    }

    static func open(root: URL? = nil, foreground: Bool = true, failRestore: Bool = false)
        async throws -> Harness
    {
        let harness = Harness(
            root: root
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                    "OutgoingQueue-\(UUID().uuidString)"))
        if failRestore { harness.faults.failures = [.restore] }
        await harness.queue.activate(uid: 1)
        await harness.queue.setForegroundActive(foreground)
        return harness
    }

    func openStore(uid: Int32) async throws -> ChahuaLocalStore {
        let root = root
        return try await Task.detached {
            let scope = LocalStorageScope(
                apiBaseURL: URL(string: "https://queue.invalid/api")!, userID: uid)
            return try ChahuaLocalStore(directory: scope.directory(under: root))
        }.value
    }

    func close() async {
        faults.release()
        queue.requestSession(uid: nil)
        await api.finishAll()
        await queue.deactivate()
    }
}

private enum QueueTestError: Error { case network, storage, timeout }

private actor HeldQueueAPI: ChahuaAPIClient {
    struct Request: Sendable {
        let chatID: String
        let threadID: String?
        let body: CreateMessageBody
        var singleForward: ForwardMessageBody? = nil
        var mergedForward: ForwardMessagesBody? = nil
        var sourceMessageID: MessageID? = nil
    }

    struct PatchRequest: Sendable {
        let chatID: String
        let messageID: MessageID
        let body: UpdateMessageBody
    }
    struct DeleteRequest: Sendable {
        let chatID: String
        let messageID: MessageID
    }

    private var recorded: [Request] = []
    private var held: [Int: CheckedContinuation<MessageResponse, Error>] = [:]
    private var active: [String: Int] = [:]
    private var maximum: [String: Int] = [:]
    private var patches: [PatchRequest] = []
    private var deletes: [DeleteRequest] = []
    private var reads: [DeleteRequest] = []
    private var heldPatches: [Int: CheckedContinuation<MessageResponse, Error>] = [:]
    private var heldDeletes: [Int: CheckedContinuation<Void, Error>] = [:]
    private var readResponses: [MessageID: MessageResponse] = [:]
    private var holdsAttachmentConfigurations = false
    private var configurationCount = 0
    private var heldConfigurations: [Int: CheckedContinuation<AttachmentConfigResponse, Error>] =
        [:]

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
        guard holdsAttachmentConfigurations else { throw APIError.unavailable }
        let index = configurationCount
        configurationCount += 1
        return try await withCheckedThrowingContinuation { heldConfigurations[index] = $0 }
    }
    func requestAttachmentUpload(
        fileName: String, contentType: String, purpose: AttachmentUploadPurpose,
        size: Int64, width: Int, height: Int, order: Int
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
        reads.append(DeleteRequest(chatID: chatID, messageID: messageID))
        guard let response = readResponses[messageID] else { throw APIError.unavailable }
        return response
    }

    func getReactionDetails(chatID: String, messageID: MessageID) async throws
        -> ReactionDetailResponse
    {
        throw APIError.unavailable
    }
    func deleteMessage(chatID: String, messageID: MessageID) async throws {
        let index = deletes.count
        deletes.append(DeleteRequest(chatID: chatID, messageID: messageID))
        try await withCheckedThrowingContinuation { heldDeletes[index] = $0 }
    }

    func updateMessage(chatID: String, messageID: MessageID, body: UpdateMessageBody) async throws
        -> MessageResponse
    {
        let index = patches.count
        patches.append(PatchRequest(chatID: chatID, messageID: messageID, body: body))
        return try await withCheckedThrowingContinuation { heldPatches[index] = $0 }
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
    func patchRequests() -> [PatchRequest] { patches }
    func deleteRequests() -> [DeleteRequest] { deletes }
    func readRequests() -> [DeleteRequest] { reads }
    func setReadResponse(_ message: MessageResponse) { readResponses[message.id] = message }

    func finishPatch(_ index: Int, with result: Result<MessageResponse, Error>) {
        heldPatches.removeValue(forKey: index)?.resume(with: result)
    }

    func finishDelete(_ index: Int, with result: Result<Void, Error>) {
        heldDeletes.removeValue(forKey: index)?.resume(with: result)
    }

    func holdAttachmentConfigurations() { holdsAttachmentConfigurations = true }
    func attachmentConfigurationCount() -> Int { configurationCount }
    func finishAttachmentConfiguration(
        _ index: Int, with result: Result<AttachmentConfigResponse, Error>
    ) {
        heldConfigurations.removeValue(forKey: index)?.resume(with: result)
    }

    func finish(_ index: Int, with result: Result<MessageResponse, Error>) {
        guard let continuation = held.removeValue(forKey: index) else { return }
        active[recorded[index].chatID, default: 0] -= 1
        continuation.resume(with: result)
    }

    func finishAll() {
        for index in Array(held.keys) { finish(index, with: .failure(CancellationError())) }
        for index in Array(heldPatches.keys) {
            finishPatch(index, with: .failure(CancellationError()))
        }
        for index in Array(heldDeletes.keys) {
            finishDelete(index, with: .failure(CancellationError()))
        }
        for index in Array(heldConfigurations.keys) {
            finishAttachmentConfiguration(index, with: .failure(CancellationError()))
        }
    }
}
