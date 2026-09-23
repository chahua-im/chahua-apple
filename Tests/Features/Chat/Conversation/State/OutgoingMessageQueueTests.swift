import ChahuaAPI
import Combine
import Foundation
import XCTest
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
@testable import chahua_apple

@MainActor
final class OutgoingMessageQueueTests: XCTestCase {
    func testStickerSnapshotsAndFailedThreadSendSurviveRestartWithoutConsumingDrafts() async throws {
        let h = try await openHarness(foreground: false)
        let sticker = MessageStickerResponse(
            id: "sticker", emoji: "wave", createdAt: Date(timeIntervalSince1970: 1), isFavorited: true,
            media: MessageStickerMediaResponse(id: "media", url: "https://example.test/sticker.webp",
                contentType: "image/webp", size: 123, width: 200, height: 150),
            name: "Wave", description: "A wave")
        let reply = try TimelineTestFixtures.message(id: "quoted", at: 1).replyPreview
        try await h.queue.saveDraft(chatID: "chat", threadID: "thread", text: "unfinished",
            editRevision: 1, updatedAt: Date(), replyToMessage: reply)
        let draft = h.queue.snapshots[ConversationKey(chatID: "chat", threadID: "thread")]?.draft
        try await h.queue.enqueueSticker(chatID: "chat", sticker: sticker)
        try await h.queue.enqueueSticker(chatID: "chat", threadID: "thread", sticker: sticker, replyToMessage: reply)
        let parent = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").first)
        let thread = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat", threadID: "thread").first)
        XCTAssertEqual(h.queue.snapshots[thread.conversationKey]?.draft, draft)
        await h.close()

        let reopened = try await openHarness(root: h.root, foreground: false)
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "chat").first?.sticker, sticker)
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "chat", threadID: "thread").first?.sticker, sticker)
        XCTAssertEqual(reopened.queue.snapshots[thread.conversationKey]?.draft, draft)
        await reopened.queue.setForegroundActive(true)
        try await eventually { await reopened.api.requests().count == 2 }
        let requests = await reopened.api.requests()
        let parentIndex = try XCTUnwrap(requests.firstIndex { $0.threadID == nil })
        let threadIndex = try XCTUnwrap(requests.firstIndex { $0.threadID == "thread" })
        XCTAssertEqual(requests[parentIndex].body, CreateMessageBody(
            messageType: .sticker, clientGeneratedId: parent.clientGeneratedID, stickerId: sticker.id))
        XCTAssertEqual(requests[threadIndex].body, CreateMessageBody(
            messageType: .sticker, clientGeneratedId: thread.clientGeneratedID, replyToId: reply.id, stickerId: sticker.id))
        await reopened.api.finish(parentIndex, with: .success(try response(requests[parentIndex])))
        await reopened.api.finish(threadIndex, with: .failure(QueueTestError.network))
        try await eventually {
            reopened.queue.pendingMessages(chatID: "chat").isEmpty &&
                reopened.queue.pendingMessages(chatID: "chat", threadID: "thread").first?.state == .failed
        }
        await reopened.close()

        let retried = try await openHarness(root: h.root)
        let restored = try XCTUnwrap(retried.queue.pendingMessages(chatID: "chat", threadID: "thread").first)
        XCTAssertEqual(restored.state, .failed)
        XCTAssertEqual(restored.sticker, sticker)
        XCTAssertEqual(restored.replyToMessage, reply)
        try await retried.queue.retry(chatID: "chat", threadID: "thread",
            clientGeneratedID: thread.clientGeneratedID, scope: .message)
        try await eventually { await retried.api.requests().count == 1 }
        let request = try await firstRequest(retried.api)
        XCTAssertEqual(request.threadID, "thread")
        XCTAssertEqual(request.body, requests[threadIndex].body)
        await retried.api.finish(0, with: .success(try response(request)))
        try await eventually { retried.queue.pendingMessages(chatID: "chat", threadID: "thread").isEmpty }
        XCTAssertEqual(retried.queue.snapshots[thread.conversationKey]?.draft, draft)
    }

    func testStickerSubmissionConsumesOnlyReplyAndPreservesTypedDraftAfterRestart() async throws {
        let h = try await openHarness(foreground: false)
        let drafts = ChatDraftStore(outgoingQueue: h.queue)
        let observation = h.queue.events.sink { event in
            if case .snapshot(let snapshot) = event { drafts.install(snapshot) }
        }
        let sticker = MessageStickerResponse(
            id: "sticker", emoji: "wave", createdAt: Date(timeIntervalSince1970: 1), isFavorited: false,
            media: MessageStickerMediaResponse(id: "media", url: "https://example.test/sticker.webp",
                contentType: "image/webp", size: 123, width: 200, height: 150),
            name: nil, description: nil)
        let reply = try TimelineTestFixtures.message(id: "quoted", at: 1).replyPreview
        drafts.setDraftText("keep typing", chatID: "chat", threadID: "thread")
        drafts.setDraftReply(reply, chatID: "chat", threadID: "thread")
        h.faults.failures = [.saveDraft]
        await drafts.flushDraft(chatID: "chat", threadID: "thread")
        XCTAssertTrue(drafts.draftSaveFailed)

        let submitted = try await drafts.submitSticker(sticker, chatID: "chat", threadID: "thread")
        XCTAssertTrue(submitted)
        XCTAssertEqual(drafts.draftText(chatID: "chat", threadID: "thread"), "keep typing")
        XCTAssertNil(drafts.draftReply(chatID: "chat", threadID: "thread"))
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat", threadID: "thread").first?.replyToMessage, reply)
        h.faults.failures = []
        await drafts.flushAll()
        observation.cancel()
        drafts.reset()
        await h.close()

        let reopened = try await openHarness(root: h.root, foreground: false)
        let snapshot = try XCTUnwrap(reopened.queue.snapshots[ConversationKey(chatID: "chat", threadID: "thread")])
        XCTAssertEqual(snapshot.draft.text, "keep typing")
        XCTAssertNil(snapshot.draft.replyToMessage)
        XCTAssertEqual(snapshot.outgoing.first?.sticker, sticker)
    }

    func testThreadSendRetryAndAcknowledgementsUseOnlyTheirConversation() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", threadID: "one", text: "reply", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        let first = try await firstRequest(h.api)
        XCTAssertEqual(first.chatID, "chat")
        XCTAssertEqual(first.threadID, "one")
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually { h.queue.pendingMessages(chatID: "chat", threadID: "one").first?.state == .failed }
        try await h.queue.enqueueText(chatID: "chat", text: "parent", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 2 }
        try await h.queue.enqueueText(chatID: "chat", threadID: "two", text: "other reply", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 3 }
        let requests = await h.api.requests()
        XCTAssertNil(requests[1].threadID)
        XCTAssertEqual(requests[2].threadID, "two")
        let wrongRoot = try TimelineTestFixtures.message(id: "wrong", at: 1, clientGeneratedID: first.body.clientGeneratedId, fields: ["replyRootId": "two"])
        let acceptedWrongRoot = await h.queue.acceptAcknowledgement(wrongRoot)
        XCTAssertFalse(acceptedWrongRoot)
        let wrongParent = try TimelineTestFixtures.message(id: "wrong-parent", at: 1, clientGeneratedID: first.body.clientGeneratedId)
        let acceptedWrongParent = await h.queue.acceptAcknowledgement(wrongParent)
        XCTAssertFalse(acceptedWrongParent)
        try await h.queue.retry(chatID: "chat", threadID: "one", clientGeneratedID: first.body.clientGeneratedId, scope: .messageAndSubsequent)
        try await eventually { await h.api.requests().count == 4 }
        let retried = await h.api.requests()
        XCTAssertEqual(retried[3].threadID, "one")
        XCTAssertEqual(retried[3].body.clientGeneratedId, first.body.clientGeneratedId)
        XCTAssertEqual(retried[3].body.message, "reply")
        let accepted = await h.queue.acceptAcknowledgement(try response(retried[3]))
        XCTAssertTrue(accepted)
        await h.api.finish(3, with: .failure(QueueTestError.network))
        await h.api.finish(1, with: .success(try response(requests[1])))
        await h.api.finish(2, with: .success(try response(requests[2])))
        try await eventually {
            h.queue.pendingMessages(chatID: "chat").isEmpty &&
                h.queue.pendingMessages(chatID: "chat", threadID: "one").isEmpty &&
                h.queue.pendingMessages(chatID: "chat", threadID: "two").isEmpty
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
        XCTAssertTrue(reopened.queue.pendingMessages(chatID: "chat").isEmpty)
        XCTAssertTrue(reopened.queue.pendingMessages(chatID: "chat", threadID: "one").isEmpty)
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "chat", threadID: "two").map(\.text), ["thread send"])
        await reopened.queue.setForegroundActive(true)
        try await eventually { await reopened.api.requests().count == 1 }
        let request = try await firstRequest(reopened.api)
        XCTAssertEqual(request.chatID, "chat")
        XCTAssertEqual(request.threadID, "two")
        await reopened.api.finish(0, with: .success(try response(request)))
        try await eventually { reopened.queue.pendingMessages(chatID: "chat", threadID: "two").isEmpty }
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
        try await eventually { h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .queued, .queued] }
        XCTAssertTrue(transitions.contains([.failed, .queued, .queued]))
        XCTAssertFalse(transitions.contains([.failed, .failed, .failed]))
        try await h.queue.enqueueText(chatID: "other", text: "independent", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 2 }
        let requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.chatID), ["chat", "other"])
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.clientGeneratedID), rows.map(\.clientGeneratedID))
        observation.cancel()
        await h.close()
    }

    func testRetrySuccessorCannotBypassFailedHeadOrChangeFIFOIdentity() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.enqueueText(chatID: "chat", text: "D", clearedDraftRevision: 4)
        for scope in [OutgoingRetryScope.message, .messageAndSubsequent] {
            try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[1].clientGeneratedID, scope: scope)
        }
        let pausedRequests = await h.api.requests()
        XCTAssertEqual(pausedRequests.map(\.body.message), ["A"])
        let pending = h.queue.pendingMessages(chatID: "chat")
        XCTAssertEqual(pending.map(\.text), ["A", "B", "C", "D"])
        XCTAssertEqual(pending.map(\.state), [.failed, .queued, .queued, .queued])
        XCTAssertEqual(Array(pending.prefix(3)).map(\.clientGeneratedID), rows.map(\.clientGeneratedID))
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID, scope: .message)
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
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID, scope: .messageAndSubsequent)
        try await eventually { await h.api.requests().count == 2 }
        for _ in 0..<3 {
            try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID, scope: .messageAndSubsequent)
        }
        var requests = await h.api.requests()
        XCTAssertEqual(requests.count, 2)
        for index in 1...3 {
            XCTAssertEqual(requests[index].body.clientGeneratedId, rows[index - 1].clientGeneratedID)
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
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID, scope: .messageAndSubsequent)
        try await eventually { await h.api.requests().count == 2 }
        await h.api.finish(1, with: .failure(QueueTestError.network))
        try await eventually { h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .queued, .queued] }
        let requests = await h.api.requests()
        XCTAssertEqual(requests.map(\.body.message), ["A", "A"])
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID, scope: .message)
        try await eventually { await h.api.requests().count == 3 }
        let repeated = await h.api.requests()
        XCTAssertEqual(repeated[0].body, repeated[1].body)
        XCTAssertEqual(repeated[1].body, repeated[2].body)
        await h.close()
    }

    func testBlockedTailWaitsForReleaseAndRetainsCompositionIdentity() async throws {
        let h = try await openHarness()
        try await h.queue.enqueueText(chatID: "chat", text: "A", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 1 }
        try await h.queue.enqueueText(chatID: "chat", text: "B", clearedDraftRevision: 2)
        let tail = try XCTUnwrap(h.queue.pendingMessages(chatID: "chat").last)
        try await h.queue.blockTail(
            chatID: "chat", itemID: tail.clientGeneratedID, expectedRevision: tail.editRevision)
        let key = ConversationKey(chatID: "chat")
        let composition = try XCTUnwrap(h.queue.snapshots[key]?.composingItem)
        XCTAssertEqual(composition.clientGeneratedID, tail.clientGeneratedID)
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.text), ["A"])
        let first = try await firstRequest(h.api)
        await h.api.finish(0, with: .success(try response(first)))
        try await eventually { h.queue.pendingMessages(chatID: "chat").isEmpty }
        try await h.queue.enqueueText(chatID: "other", text: "independent", clearedDraftRevision: 1)
        try await eventually { await h.api.requests().count == 2 }
        let whileBlocked = await h.api.requests()
        XCTAssertEqual(whileBlocked.map(\.body.message), ["A", "independent"])
        XCTAssertEqual(h.queue.snapshots[key]?.composingItem?.text, "B")
        try await h.queue.enqueueText(
            chatID: "chat", text: "edited B", clearedDraftRevision: composition.editRevision + 1)
        try await eventually { await h.api.requests().count == 3 }
        let released = await h.api.requests()
        XCTAssertEqual(released[2].body.clientGeneratedId, tail.clientGeneratedID)
        XCTAssertEqual(released[2].body.message, "edited B")
        XCTAssertNil(h.queue.snapshots[key]?.composingItem)
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

    func testRestartReplaysInterruptedHeadBeforeQueuedSuccessors() async throws {
        let h = try await openHarness()
        let rows = try await pausedABC(h)
        try await h.queue.retry(chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID, scope: .messageAndSubsequent)
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
        let reply = try TimelineTestFixtures.message(id: "target", at: 0).replyPreview
        try await h.queue.enqueueText(chatID: "chat", text: "answer", clearedDraftRevision: 1, replyToMessage: reply)
        try await eventually { await h.api.requests().count == 1 }
        let original = try await firstRequest(h.api)
        XCTAssertEqual(original.body.replyToId, reply.id)
        await h.api.finish(0, with: .failure(QueueTestError.network))
        try await eventually { h.queue.pendingMessages(chatID: "chat").first?.state == .failed }
        await h.close()

        let restored = try await openHarness(root: h.root)
        XCTAssertEqual(restored.queue.pendingMessages(chatID: "chat").first?.replyToMessage, reply)
        try await restored.queue.retry(chatID: "chat", clientGeneratedID: original.body.clientGeneratedId, scope: .message)
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
        let reply = try TimelineTestFixtures.message(id: "quoted", at: 1).replyPreview
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
        try await h.queue.saveDraft(chatID: "chat", text: "hello\n世界", editRevision: 1, updatedAt: Date())
        h.faults.failures = [.enqueue]
        do {
            try await h.queue.enqueueText(chatID: "chat", text: "hello\n世界", clearedDraftRevision: 2)
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
        XCTAssertFalse(h.queue.snapshots[ConversationKey(chatID: "chat")]!.outgoing.contains { $0.clientGeneratedID == message.clientGeneratedId })
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
        XCTAssertEqual(h.queue.pendingMessages(chatID: "chat").map(\.state), [.failed, .queued, .queued])
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
        XCTAssertEqual(reopened.queue.pendingMessages(chatID: "chat").map(\.state), [.failed, .queued, .queued])
        await reopened.queue.setForegroundActive(false)
        await reopened.queue.setForegroundActive(true)
        let requests = await reopened.api.requests()
        XCTAssertEqual(requests.count, 0)
        try await reopened.queue.retry(chatID: "chat", clientGeneratedID: rows[0].clientGeneratedID, scope: .message)
        try await eventually { await reopened.api.requests().count == 1 }
        let retried = try await firstRequest(reopened.api)
        XCTAssertEqual(retried.body.clientGeneratedId, rows[0].clientGeneratedID)
        XCTAssertEqual(retried.body.message, "A")
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

    func testRestoredMediaSendUsesSubmissionTimeAndKeepsSenderVisibleThroughAcknowledgement() async throws {
        let h = try await openHarness(foreground: false)
        let chatStore = ChatStore(apiClient: h.api, outgoingQueue: h.queue, onInvalidToken: {})
        defer { chatStore.cancelRealtimeRecovery() }
        let profile = try JSONDecoder().decode(MeResponse.self, from: Data(#"""
        {"uid": 1, "username": "Ada", "gender": 2, "stickerPackOrder": [], "permissions": []}
        """#.utf8))
        chatStore.currentUserProfile = profile
        // A long-lived caption draft would previously sort between the two
        // earlier outgoing messages, hiding both its sender header and avatar.
        try await h.queue.saveDraft(chatID: "chat", text: "Caption", editRevision: 1,
                                    updatedAt: TimelineTestFixtures.date(second: 1))
        let image = h.root.appendingPathComponent("selected.png")
        try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: image)
        try await h.queue.importImages(urls: [image], chatID: "chat")
        let composition = try XCTUnwrap(h.queue.snapshots[ConversationKey(chatID: "chat")]?.composingItem)
        let localStore = try await h.openStore(uid: 1)
        _ = try await localStore.enqueueText(
            chatID: "chat", senderID: 1, clientGeneratedID: "unused", text: "Caption",
            enqueuedAt: TimelineTestFixtures.date(second: 4), clearedDraftRevision: composition.editRevision + 1)
        await h.queue.retryStorage()

        let history = try [
            TimelineTestFixtures.message(id: "before-draft", at: 0),
            TimelineTestFixtures.message(id: "after-draft", at: 2),
            TimelineTestFixtures.message(id: "incoming", senderID: 2, at: 3),
        ]
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
        let native = TimelineRowView(frame: .zero)
        var actions = TimelineBubbleActions()
        actions.currentUserProfile = profile
        func assertSenderVisible(remote: [MessageResponse]) throws -> TimelineMessageRow {
            let projection = chatStore.conversationMessages.projection(
                for: "chat", remoteMessages: remote, includePendingOutgoing: true)
            let rows = TimelineRowsBuilder(currentUserID: 1, isGroupChat: true, calendar: .current).build(projection.entries)
            let row = try XCTUnwrap(rows.compactMap { row -> TimelineMessageRow? in
                guard case .message(let message) = row,
                      message.entry.stableKey == .clientGenerated(composition.clientGeneratedID) else { return nil }
                return message
            }.first)
            XCTAssertEqual(row.groupPosition, .single)
            let presentation = TimelineRowPresentation.make(
                row: .message(row), currentUserProfile: profile, currentUserID: 1,
                isThreadTimeline: false, environment: environment)
            XCTAssertEqual(presentation.title?.name, "Ada")
            let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
            XCTAssertNotNil(layout.frames[.title])
            XCTAssertNotNil(layout.frames[.avatar])
            native.frame = CGRect(origin: .zero, size: layout.size)
            native.bind(.init(presentation: presentation, layout: layout, context: .init(),
                              actions: actions, mediaContext: nil))
            #if os(macOS)
            native.layoutSubtreeIfNeeded()
            let avatar = try XCTUnwrap(native.subviews.compactMap { $0 as? TimelineAvatarView }.first)
            XCTAssertFalse(avatar.isHidden)
            XCTAssertTrue(avatar.accessibilityLabel()?.contains("Ada") == true)
            #elseif os(iOS)
            native.layoutIfNeeded()
            let avatar = try XCTUnwrap(native.subviews.flatMap(\.subviews).compactMap { $0 as? TimelineAvatarView }.first)
            XCTAssertFalse(avatar.isHidden)
            XCTAssertTrue(avatar.accessibilityLabel?.contains("Ada") == true)
            #endif
            return row
        }
        let pending = try assertSenderVisible(remote: history)
        XCTAssertEqual(pending.entry.displayState, .queued)
        let acknowledgement = try TimelineTestFixtures.message(
            id: "confirmed-media", at: 5, text: "Caption", clientGeneratedID: composition.clientGeneratedID,
            fields: ["hasAttachments": true, "attachments": [[
                "id": "image", "url": "https://example.invalid/image.png", "kind": "image/png",
                "size": 1, "fileName": "image.png", "width": 1, "height": 1,
            ]]])
        let accepted = await h.queue.acceptAcknowledgement(acknowledgement)
        XCTAssertTrue(accepted)
        let confirmed = try assertSenderVisible(remote: history + [acknowledgement])
        XCTAssertEqual(confirmed.entry.stableKey, pending.entry.stableKey)
        XCTAssertEqual(confirmed.entry.displayState, .delivered)
    }

    func testDiscardDraftAttachmentsPreservesCaptionReplyAndPendingSendsAcrossRestart() async throws {
        let h = try await openHarness(foreground: false)
        try await h.queue.enqueueText(chatID: "chat", threadID: "thread", text: "thread send", clearedDraftRevision: 1)
        try await h.queue.enqueueText(chatID: "chat", text: "parent send", clearedDraftRevision: 1)
        try await h.queue.enqueueText(chatID: "other", text: "other send", clearedDraftRevision: 1)
        try await h.queue.saveDraft(chatID: "chat", text: "parent draft", editRevision: 2, updatedAt: Date())
        let reply = try TimelineTestFixtures.message(id: "target", at: 0).replyPreview
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
        } catch LocalStorageError.staleDraft { }
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
        let revision = try XCTUnwrap(h.queue.snapshots[ConversationKey(chatID: "chat", threadID: nil)]?.draft.editRevision)
        try await h.queue.enqueueText(chatID: "chat", text: "", clearedDraftRevision: revision + 1)
        await h.queue.setForegroundActive(true)
        // This API cannot allocate uploads: dispatch proves neither completed slot was restarted.
        try await eventually { await h.api.requests().count == 1 }
        let request = try await firstRequest(h.api)
        XCTAssertEqual(request.body.attachmentIds, ["remote-1", "remote-0"])
        XCTAssertEqual(request.body.clientGeneratedId, item.clientGeneratedID)
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
        try await eventually { h.queue.pendingMessages(chatID: "chat").map(\.state) == [.failed, .queued, .queued] }
        return rows
    }

    private func response(_ request: HeldQueueAPI.Request) throws -> MessageResponse {
        try TimelineTestFixtures.message(id: "server-\(request.body.clientGeneratedId)", chatID: request.chatID, at: 1, type: request.body.messageType, clientGeneratedID: request.body.clientGeneratedId, fields: request.threadID.map { ["replyRootId": $0] } ?? [:])
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
        let threadID: String?
        let body: CreateMessageBody
    }

    private var recorded: [Request] = []
    private var held: [Int: CheckedContinuation<MessageResponse, Error>] = [:]
    private var active: [String: Int] = [:]
    private var maximum: [String: Int] = [:]

    func authenticate(candidateJWT: String) async throws -> MeResponse { throw APIError.unavailable }
    func createDevSession(uid: Int32, clientID: String) async throws -> String { throw APIError.unavailable }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func attachmentConfig() async throws -> AttachmentConfigResponse { throw APIError.unavailable }
    func requestAttachmentUpload(fileName: String, contentType: String, size: Int64, width: Int, height: Int, order: Int) async throws -> OutgoingUploadAllocation { throw APIError.unavailable }
    func listOwnedStickerPacks() async throws -> [StickerPackSummary] { throw APIError.unavailable }
    func listSubscribedStickerPacks() async throws -> [StickerPackSummary] { throw APIError.unavailable }
    func listFavoriteStickers() async throws -> [MessageStickerResponse] { throw APIError.unavailable }
    func getSticker(id: String) async throws -> StickerDetailResponse { throw APIError.unavailable }
    func getStickerPack(id: String) async throws -> StickerPackDetailResponse { throw APIError.unavailable }
    func setStickerFavorite(id: String, favorite: Bool) async throws { throw APIError.unavailable }
    func setStickerPackSubscription(id: String, subscribed: Bool) async throws { throw APIError.unavailable }
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse { throw APIError.unavailable }
    func archiveChat(chatID: String) async throws { throw APIError.unavailable }
    func unarchiveChat(chatID: String) async throws { throw APIError.unavailable }
    func archiveThread(chatID: String, threadID: String) async throws { throw APIError.unavailable }
    func unarchiveThread(chatID: String, threadID: String) async throws { throw APIError.unavailable }
    func muteChat(chatID: String, durationSeconds: Int?) async throws -> MuteResponse { throw APIError.unavailable }
    func unmuteChat(chatID: String) async throws { throw APIError.unavailable }
    func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse { throw APIError.unavailable }
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse { throw APIError.unavailable }
    func groupInfo(chatID: String) async throws -> GroupInfoResponse { throw APIError.unavailable }
    func listMembers(chatID: String, query: ListMembersQuery) async throws -> ListMembersResponse { throw APIError.unavailable }
    func updateGroupMemberRole(chatID: String, uid: Int32, role: GroupRole) async throws -> MemberResponse { throw APIError.unavailable }
    func removeGroupMember(chatID: String, uid: Int32) async throws { throw APIError.unavailable }
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse { throw APIError.unavailable }
    func getMessage(chatID: String, messageID: String) async throws -> MessageResponse { throw APIError.unavailable }
    func deleteMessage(chatID: String, messageID: String) async throws { throw APIError.unavailable }
    func markChatRead(chatID: String, messageID: String) async throws -> ReadStateResponse { throw APIError.unavailable }
    func markChatUnread(chatID: String) async throws -> ReadStateResponse { throw APIError.unavailable }
    func markThreadRead(chatID: String, threadID: String, messageID: String) async throws -> ReadStateResponse { throw APIError.unavailable }
    func putReaction(chatID: String, messageID: String, emoji: String) async throws { throw APIError.unavailable }
    func deleteReaction(chatID: String, messageID: String, emoji: String) async throws { throw APIError.unavailable }

    // Intentionally ignores cancellation until explicitly completed, exercising late responses.
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse {
        try await hold(chatID: chatID, threadID: nil, body: body)
    }

    func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody) async throws -> MessageResponse {
        try await hold(chatID: chatID, threadID: threadID, body: body)
    }

    private func hold(chatID: String, threadID: String?, body: CreateMessageBody) async throws -> MessageResponse {
        let index = recorded.count
        recorded.append(Request(chatID: chatID, threadID: threadID, body: body))
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
