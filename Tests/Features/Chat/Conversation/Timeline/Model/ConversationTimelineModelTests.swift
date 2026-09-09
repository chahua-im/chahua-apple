import Combine
import XCTest
@testable import chahua_apple
import ChahuaAPI

@MainActor
final class ConversationTimelineModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func testContinuedUserScrollingDoesNotRepublishUnchangedState() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1 ... 2))])
        await model.loadInitial()
        var stateChanges = 0
        let observation = model.objectWillChange.sink { stateChanges += 1 }
        defer { observation.cancel() }

        model.userScrollBegan()
        XCTAssertFalse(model.state.live.followsLatest)
        XCTAssertNil(model.updates.value.pendingScroll)
        XCTAssertEqual(stateChanges, 1)

        for _ in 0 ..< 120 { model.userScrollBegan() }
        XCTAssertEqual(stateChanges, 1, "Continued wheel events must not invalidate the SwiftUI timeline.")

        source.store.apply(.message(try TimelineTestFixtures.message(id: "3", senderID: 2, at: 3)))
        XCTAssertFalse(model.state.live.followsLatest)
        XCTAssertEqual(model.state.live.unseenCount, 1)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1", "2", "3"])
    }

    func testInitialLoadPublishesBottomResetWithRemoteRows() async throws {
        let (model, _, updates) = try makeModel(pages: [.success(try livePage(ids: 1 ... 2))])

        await model.loadInitial()

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertTrue(model.isAtLiveEdge)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1", "2"])
        XCTAssertEqual(updates.value.last?.pendingScroll?.intent, .bottom(animated: false))
    }

    func testInitialLoadFailureIsRetryable() async throws {
        let (model, _, _) = try makeModel(pages: [.failure(StubError()), .success(try livePage(ids: 1 ... 1))])

        await model.loadInitial()
        XCTAssertEqual(model.state.content, .initialLoadFailed)

        await model.retryInitial()
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1"])
    }

    func testRestoredFailedRowsRemainVisibleWhileInitialHistoryLoadsAndFails() async throws {
        let source = ScriptedTimelineSource(pages: [.failure(StubError())])
        var failed = pending(id: "restored")
        failed.state = .failed
        source.store.replacePending(chatID: "chat", with: [failed])
        let model = ConversationTimelineModel(chatID: "chat", currentUserID: 1, isGroupChat: true, source: source, messageStore: source.store)
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), [.clientGenerated("restored")])
        source.holdNextRequest()
        let loading = Task { await model.open() }
        await source.waitUntilHeld()
        XCTAssertEqual(model.state.content, .loadingInitial)
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), [.clientGenerated("restored")])

        source.release()
        await loading.value

        XCTAssertEqual(model.state.content, .initialLoadFailed)
        let entries = model.rows.compactMap { row -> ConversationTimelineEntry? in
            guard case .message(let message) = row else { return nil }
            return message.entry
        }
        XCTAssertEqual(entries.map(\.stableKey), [.clientGenerated("restored")])
        XCTAssertEqual(entries.map(\.displayState), [.failed])
        source.store.replacePending(chatID: "chat", with: [failed, pending(id: "new")])
        XCTAssertEqual(Set(model.rows.compactMap(\.stableMessageKey)), [.clientGenerated("restored"), .clientGenerated("new")])
    }

    func testAtomicAcknowledgementDuringInitialLoadingSurvivesFailureAndRetry() async throws {
        let acknowledged = try TimelineTestFixtures.message(id: "server", at: 1, clientGeneratedID: "send")
        let (model, source, _) = try makeModel(pages: [
            .failure(StubError()), .success(try TimelineTestFixtures.page([acknowledged])),
        ])
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])
        source.holdNextRequest()
        let loading = Task { await model.open() }
        await source.waitUntilHeld()
        var visibleKeys: [[ConversationMessageStableKey]] = []
        let observation = model.updates.sink { visibleKeys.append($0.rows.compactMap(\.stableMessageKey)) }
        defer { observation.cancel() }

        source.store.replacePending(chatID: "chat", with: [], acknowledging: acknowledged)
        XCTAssertEqual(model.state.content, .loadingInitial)
        XCTAssertEqual(remoteMessages(model).map(\.id), ["server"])
        source.store.apply(.message(try TimelineTestFixtures.message(id: "unrelated", senderID: 2, at: 2)))
        XCTAssertEqual(remoteMessages(model).map(\.id), ["server"], "Only matched acknowledgements are exposed before history succeeds")
        source.release()
        await loading.value
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        XCTAssertEqual(remoteMessages(model).map(\.id), ["server"])

        source.holdNextRequest()
        let retrying = Task { await model.retryInitial() }
        await source.waitUntilHeld()
        XCTAssertEqual(remoteMessages(model).map(\.id), ["server"])
        source.release()
        await retrying.value
        XCTAssertEqual(model.rows.filter { $0.stableMessageKey == .clientGenerated("send") }.count, 1)
        XCTAssertTrue(visibleKeys.allSatisfy { $0.filter { $0 == .clientGenerated("send") }.count == 1 })
        XCTAssertEqual(model.state.live.unseenCount, 0)
    }

    func testAcknowledgementAfterInitialFailureRemainsDeliveredUntilSnapshot() async throws {
        let acknowledged = try TimelineTestFixtures.message(id: "server", at: 1, clientGeneratedID: "send")
        let (model, source, _) = try makeModel(pages: [
            .failure(StubError()), .success(try TimelineTestFixtures.page([acknowledged])),
        ])
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])
        await model.open()
        source.store.replacePending(chatID: "chat", with: [], acknowledging: acknowledged)
        source.store.replacePending(chatID: "chat", with: [])
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        XCTAssertEqual(remoteMessages(model).map(\.id), ["server"])
        await model.retryInitial()
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), [.clientGenerated("send")])
        XCTAssertEqual(remoteMessages(model).map(\.id), ["server"])
    }

    func testRevealAfterDurableEnqueueReusesNearbyLiveWindowWithoutWritingAgain() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1 ... 2))])
        await model.open()
        model.userScrollBegan()
        model.viewportDidChange(.init(firstVisibleIndex: 0, lastVisibleIndex: model.rows.count - 1, distanceToTop: 5_000, distanceToBottom: 100, height: 400), reason: .user, revision: model.updates.value.revision)
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])

        await model.revealLatestAfterSend()

        XCTAssertEqual(source.queries.count, 1)
        XCTAssertEqual(model.rows.filter { $0.stableMessageKey == .clientGenerated("send") }.count, 1)
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: true))
        XCTAssertTrue(model.state.live.followsLatest)
    }

    func testLiveMessageOffLiveEdgeIsDeferredAndCounted() async throws {
        let (model, source, updates) = try makeModel(pages: [.success(try historyPage(ids: 1 ... 2, newerCursor: "2"))])
        await model.loadInitial()
        XCTAssertFalse(model.isAtLiveEdge)
        let updatesBefore = updates.value.count

        source.store.apply(.message(try TimelineTestFixtures.message(id: "3", senderID: 2, at: 3)))

        XCTAssertEqual(model.state.live.unseenCount, 1)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1", "2"], "history view must not render the deferred message")
        XCTAssertEqual(updates.value.count, updatesBefore, "deferred arrival publishes nothing")
    }

    func testLiveMessageAtPinnedLiveEdgeAppendsAndFollows() async throws {
        let (model, source, updates) = try makeModel(pages: [.success(try livePage(ids: 1 ... 1))])
        await model.loadInitial()

        source.store.apply(.message(try TimelineTestFixtures.message(id: "2", senderID: 2, at: 2)))

        XCTAssertEqual(model.state.live.unseenCount, 0)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1", "2"])
        XCTAssertTrue(updates.value.last?.animateFollowing == true)
    }

    func testLiveMessageAtUnpinnedLiveEdgeCountsButStillRenders() async throws {
        let (model, source, updates) = try makeModel(pages: [.success(try livePage(ids: 1 ... 1))])
        await model.loadInitial()
        model.scrollRequestDidFinish(id: model.updates.value.pendingScroll!.id)
        model.userScrollBegan()
        model.viewportDidChange(.init(firstVisibleIndex: 0, lastVisibleIndex: 0, distanceToTop: 0, distanceToBottom: 500, height: 400), reason: .user, revision: model.updates.value.revision)
        XCTAssertFalse(model.state.live.isPinnedToBottom)

        source.store.apply(.message(try TimelineTestFixtures.message(id: "2", senderID: 2, at: 2)))

        XCTAssertEqual(model.state.live.unseenCount, 1)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1", "2"])
        XCTAssertNil(updates.value.last?.pendingScroll)
    }

    func testPinnedViewportAtLiveEdgeClearsUnseenCount() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1 ... 1))])
        await model.loadInitial()
        model.scrollRequestDidFinish(id: model.updates.value.pendingScroll!.id)
        model.userScrollBegan()
        model.viewportDidChange(.init(firstVisibleIndex: 0, lastVisibleIndex: 0, distanceToTop: 0, distanceToBottom: 500, height: 400), reason: .user, revision: model.updates.value.revision)
        source.store.apply(.message(try TimelineTestFixtures.message(id: "2", senderID: 2, at: 2)))
        XCTAssertEqual(model.state.live.unseenCount, 1)

        model.viewportDidChange(.init(firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0, distanceToBottom: 0, height: 400), reason: .user, revision: model.updates.value.revision)

        XCTAssertTrue(model.state.live.isPinnedToBottom)
        XCTAssertEqual(model.state.live.unseenCount, 0)
    }

    func testJumpToLiveEdgeFromHistoryReplaysDeferredArrivalNewerThanServerPage() async throws {
        let (model, source, updates) = try makeModel(pages: [
            .success(try historyPage(ids: 1 ... 2, newerCursor: "2")),
            .success(try livePage(ids: 98 ... 99)),
        ])
        await model.loadInitial()
        // Arrives after the server page's newest (99 @ 01:39) and is absent from that page.
        source.store.apply(.message(try TimelineTestFixtures.message(id: "100", senderID: 2, at: 40, minute: 1)))
        XCTAssertEqual(model.state.live.unseenCount, 1)

        await model.jumpToLiveEdge()

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertNil(model.state.repositionFailure)
        XCTAssertTrue(model.isAtLiveEdge)
        XCTAssertEqual(model.state.live, .init(isPinnedToBottom: false, followsLatest: true, unseenCount: 1))
        XCTAssertNil(source.queries.last?.after)
        XCTAssertNil(source.queries.last?.before)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["98", "99", "100"])
        XCTAssertEqual(updates.value.last?.pendingScroll?.intent, .bottom(animated: false))
    }

    func testJumpToLiveEdgeDropsDeferredArrivalOlderThanNewWindow() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1 ... 2, newerCursor: "2")),
            .success(try livePage(ids: 98 ... 99)),
        ])
        await model.loadInitial()
        // Predates 98 @ 01:38: replaying it would render above a history gap.
        source.store.apply(.message(try TimelineTestFixtures.message(id: "3", senderID: 2, at: 3)))

        await model.jumpToLiveEdge()

        XCTAssertEqual(model.rows.compactMap(\.messageID), ["98", "99"], "stale deferred entry must not be injected above the gap")
    }

    func testInitialOpenUsesHTTPRatherThanEventsFromAPriorScreen() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 98 ... 99))])
        source.store.apply(.message(try TimelineTestFixtures.message(id: "100", at: 40, minute: 1)))
        await model.open()
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["98", "99"])
    }

    func testLatestSnapshotReconcilesDeferredCreatesByIdentityAndRetainsEqualTimeArrivals() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1 ... 2, newerCursor: "2")),
            .success(try livePage(ids: 98 ... 99)),
        ])
        await model.loadInitial()
        source.store.apply(.message(try TimelineTestFixtures.message(id: "99", senderID: 2, at: 39, minute: 1)))
        source.store.apply(.message(try TimelineTestFixtures.message(id: "99b", senderID: 2, at: 39, minute: 1)))
        await model.jumpToLiveEdge()
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["98", "99", "99b"])
    }

    func testJumpToLiveEdgeFailureIsAnOverlayThatKeepsPagingAlive() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 10 ... 11, olderCursor: "10", newerCursor: "11")),
            .failure(StubError()),
            .success(try historyPage(ids: 8 ... 9, olderCursor: "8", newerCursor: "9")),
        ])
        await model.loadInitial()

        await model.jumpToLiveEdge()

        XCTAssertEqual(model.state.content, .ready, "failure must not park the lifecycle")
        XCTAssertEqual(model.state.repositionFailure, .liveEdge)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["10", "11"])

        // Paging is still live while the failure banner is showing.
        model.viewportDidChange(.init(firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0, distanceToBottom: 5_000, height: 400), reason: .user, revision: model.updates.value.revision)
        await source.drain()
        XCTAssertEqual(source.queries.last?.before, "10")
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["8", "9", "10", "11"])
        XCTAssertEqual(model.state.repositionFailure, .liveEdge, "paging does not clear the banner")

        model.dismissRepositionFailure()
        XCTAssertNil(model.state.repositionFailure)
    }

    func testInitialLoadAroundMissingTargetSurfacesOverlayAndStaysReady() async throws {
        let (model, _, updates) = try makeModel(pages: [.success(try livePage(ids: 1 ... 2))])

        await model.loadInitial(position: .message("404"))

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(model.state.repositionFailure, .message("404"))
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1", "2"])
        XCTAssertEqual(updates.value.last?.pendingScroll?.intent, .bottom(animated: false))
    }

    func testOlderEdgeFailureIsSurfacedAndRetryable() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 10 ... 11, olderCursor: "10", newerCursor: nil)),
            .failure(StubError()),
            .success(try historyPage(ids: 8 ... 9, olderCursor: "8", newerCursor: "9")),
        ])
        await model.loadInitial()

        model.viewportDidChange(.init(firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0, distanceToBottom: 0, height: 400), reason: .user, revision: model.updates.value.revision)
        await source.drain()
        XCTAssertEqual(model.state.older, .failed)
        XCTAssertEqual(source.queries.last?.before, "10")

        model.viewportDidChange(.init(firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0, distanceToBottom: 0, height: 400), reason: .user, revision: model.updates.value.revision)
        XCTAssertEqual(source.queries.count, 2, "failed edge must not refetch until retried")

        model.retryOlder()
        await source.drain()
        XCTAssertEqual(model.state.older, .idle)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["8", "9", "10", "11"])
    }

    func testInitialSnapshotReplaysEditReactionAndDeletionBeforePublishing() async throws {
        let old = try TimelineTestFixtures.message(id: "1", at: 1, text: "old", fields: [
            "hasAttachments": true,
            "attachments": [["id": "file", "url": "/file", "kind": "image/png", "size": 1, "fileName": "file.png"]],
        ])
        let edited = try TimelineTestFixtures.message(id: "1", at: 1, text: "new")
        let (model, source, updates) = try makeModel(pages: [.success(try TimelineTestFixtures.page([old]))])
        source.holdNextRequest()
        let loading = Task { await model.open() }
        await source.waitUntilHeld()
        source.store.apply(.messageUpdated(edited))
        source.store.apply(.reactionUpdated(.init(messageId: "1", chatId: "chat", reactions: try reactionFixture())))
        source.store.apply(.messageDeleted(edited.redactedForDeletion()))
        source.release()
        await loading.value

        let final = try XCTUnwrap(remoteMessages(model).first)
        XCTAssertEqual(final.id, "1")
        XCTAssertTrue(final.isDeleted)
        XCTAssertNil(final.message)
        XCTAssertFalse(final.hasAttachments)
        XCTAssertTrue(final.attachments.isEmpty)
        XCTAssertTrue(final.reactions.isEmpty)
        XCTAssertEqual(model.state.live.unseenCount, 0)
        XCTAssertFalse(updates.value.contains { snapshot in
            snapshot.rows.contains { row in
                if case .message(let row) = row { return row.entry.text == "old" }
                return false
            }
        }, "No intermediate HTTP baseline may reach a native host")
    }

    func testOlderPageReplaysUnknownEditWithoutLosingRowsOutsideFetchedScope() async throws {
        let old = try TimelineTestFixtures.message(id: "1", at: 1, text: "old")
        let edited = try TimelineTestFixtures.message(id: "1", at: 1, text: "new")
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 10 ... 11, olderCursor: "10", newerCursor: "11")),
            .success(try TimelineTestFixtures.page([old])),
        ])
        await model.loadInitial()
        source.holdNextRequest()
        model.retryOlder()
        await source.waitUntilHeld()
        source.store.apply(.messageUpdated(edited))
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["10", "11"], "An unknown edit is not a create")
        source.release()
        await source.drain()
        XCTAssertEqual(remoteMessages(model).map(\.id), ["1", "10", "11"])
        XCTAssertEqual(remoteMessages(model).first?.message, "new")
        XCTAssertEqual(model.state.live.unseenCount, 0)
    }

    func testLaterHTTPMayReplaceAnEventReceivedBeforeThatRequest() async throws {
        let old = try TimelineTestFixtures.message(id: "1", at: 1, text: "old")
        let new = try TimelineTestFixtures.message(id: "1", at: 1, text: "new")
        let authoritative = try TimelineTestFixtures.message(id: "1", at: 1, text: "authoritative")
        let (model, source, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([old])),
            .success(try TimelineTestFixtures.page([authoritative])),
        ])
        await model.open()
        source.store.apply(.messageUpdated(new))
        XCTAssertEqual(remoteMessages(model).first?.message, "new")
        await model.reconcileAfterReconnect()
        XCTAssertEqual(remoteMessages(model).first?.message, "authoritative")
    }

    func testInitialCreateAndHTTPAcknowledgementConvergeWithoutUnseenOrDuplicateRows() async throws {
        let acknowledged = try TimelineTestFixtures.message(id: "1", at: 1, clientGeneratedID: "send")
        for websocketFirst in [true, false] {
            let (model, source, updates) = try makeModel(pages: [.success(try TimelineTestFixtures.page([acknowledged]))])
            source.store.enqueue(pending(id: "send"))
            source.holdNextRequest()
            let loading = Task { await model.open() }
            await source.waitUntilHeld()
            if websocketFirst { source.store.apply(.message(acknowledged)) }
            source.release()
            await loading.value
            if !websocketFirst { source.store.apply(.message(acknowledged)) }
            XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), [.clientGenerated("send")])
            XCTAssertEqual(remoteMessages(model).map(\.id), ["1"])
            XCTAssertEqual(model.state.live.unseenCount, 0)
            XCTAssertFalse(updates.value.contains { $0.animateFollowing })
        }
    }

    func testDuplicateCreateAndLateAcknowledgementCannotUndoEditOrDelete() async throws {
        let created = try TimelineTestFixtures.message(id: "1", at: 1, text: "old", clientGeneratedID: "send")
        let edited = try TimelineTestFixtures.message(id: "1", at: 1, text: "new", clientGeneratedID: "send")
        let (model, source, _) = try makeModel(pages: [.success(try TimelineTestFixtures.page([]))])
        await model.open()
        source.store.enqueue(pending(id: "send"))
        var visibleKeys: [[ConversationMessageStableKey]] = []
        let observation = model.updates.sink { visibleKeys.append($0.rows.compactMap(\.stableMessageKey)) }
        defer { observation.cancel() }
        source.store.apply(.message(created))
        source.store.apply(.messageUpdated(edited))
        source.store.apply(.message(created))
        source.store.acknowledge(created)
        XCTAssertEqual(remoteMessages(model).map(\.message), ["new"])
        XCTAssertTrue(visibleKeys.allSatisfy { $0 == [.clientGenerated("send")] })
        source.store.apply(.messageDeleted(edited.redactedForDeletion()))
        source.store.apply(.messageUpdated(edited))
        source.store.apply(.reactionUpdated(.init(messageId: "1", chatId: "chat", reactions: try reactionFixture())))
        XCTAssertTrue(try XCTUnwrap(remoteMessages(model).first).isDeleted)
        XCTAssertNil(remoteMessages(model).first?.message)
        XCTAssertEqual(remoteMessages(model).first?.reactions, [])
    }

    func testTwoModelsHaveIndependentHistoryGapsAndUnseenState() async throws {
        let source = ScriptedTimelineSource(pages: [
            .success(try historyPage(ids: 1 ... 2, newerCursor: "2")),
            .success(try livePage(ids: 1 ... 2)),
            .success(try livePage(ids: 3 ... 3)),
        ])
        let historical = ConversationTimelineModel(chatID: "chat", currentUserID: 1, isGroupChat: true, source: source, messageStore: source.store)
        let latest = ConversationTimelineModel(chatID: "chat", currentUserID: 1, isGroupChat: true, source: source, messageStore: source.store)
        await historical.open()
        await latest.open()
        let created = try TimelineTestFixtures.message(id: "3", at: 3)
        source.store.apply(.message(created))
        source.store.apply(.message(created))
        source.store.apply(.messageUpdated(try TimelineTestFixtures.message(id: "1", at: 1, text: "edited in both")))
        source.store.apply(.messageDeleted(try TimelineTestFixtures.message(id: "2", at: 2).redactedForDeletion()))
        XCTAssertEqual(remoteMessages(historical).map(\.id), ["1", "2"])
        XCTAssertEqual(remoteMessages(latest).map(\.id), ["1", "2", "3"])
        for model in [historical, latest] {
            XCTAssertEqual(remoteMessages(model).first?.message, "edited in both")
            XCTAssertTrue(try XCTUnwrap(remoteMessages(model).first { $0.id == "2" }).isDeleted)
        }
        XCTAssertEqual(historical.state.live.unseenCount, 1)
        XCTAssertEqual(latest.state.live.unseenCount, 0)
        await historical.jumpToLiveEdge()
        XCTAssertEqual(remoteMessages(historical).map(\.id), ["3"], "A latest replacement must not bridge the old history gap")
        XCTAssertEqual(remoteMessages(latest).map(\.id), ["1", "2", "3"])
    }

    func testDeferredMutationsRemainWindowLocalUntilLatestClosesTheGap() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1 ... 1, newerCursor: "1")),
            .success(try livePage(ids: 2 ... 2)),
        ])
        await model.open()
        let created = try TimelineTestFixtures.message(id: "3", at: 3, text: "old")
        source.store.apply(.message(created))
        source.store.apply(.messageUpdated(try TimelineTestFixtures.message(id: "3", at: 3, text: "edited")))
        source.store.apply(.messageDeleted(created.redactedForDeletion()))
        source.store.apply(.message(created))
        XCTAssertEqual(remoteMessages(model).map(\.id), ["1"])
        XCTAssertEqual(model.state.live.unseenCount, 1)
        await model.jumpToLiveEdge()
        XCTAssertEqual(remoteMessages(model).map(\.id), ["2", "3"])
        XCTAssertTrue(try XCTUnwrap(remoteMessages(model).last).isDeleted)
        XCTAssertNil(remoteMessages(model).last?.message)
    }

    func testEmptyLatestSnapshotDiscardsOldDeferredRowsButReplaysInFlightCreate() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1 ... 1, newerCursor: "1")),
            .success(try TimelineTestFixtures.page([])),
        ])
        await model.open()
        source.store.apply(.message(try TimelineTestFixtures.message(id: "2", at: 2)))
        source.holdNextRequest()
        let jumping = Task { await model.jumpToLiveEdge() }
        await source.waitUntilHeld()
        let fresh = try TimelineTestFixtures.message(id: "3", at: 3)
        source.store.apply(.message(fresh))
        source.store.apply(.messageDeleted(fresh.redactedForDeletion()))
        source.release()
        await jumping.value
        XCTAssertEqual(remoteMessages(model).map(\.id), ["3"])
        XCTAssertTrue(try XCTUnwrap(remoteMessages(model).first).isDeleted)
    }

    func testReconnectJoinsInitialOpenInsteadOfStartingACompetingReplacement() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1 ... 1))])
        source.holdNextRequest()
        let opening = Task { await model.open() }
        await source.waitUntilHeld()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.drain()
        source.release()
        await opening.value
        await recovering.value
        XCTAssertEqual(source.queries.count, 1)
        XCTAssertEqual(remoteMessages(model).map(\.id), ["1"])
    }

    func testThreadScopeFiltersHTTPAndLiveRepliesWithoutLosingRootMetadata() async throws {
        let root = try TimelineTestFixtures.message(id: "root", at: 1)
        let reply = try TimelineTestFixtures.message(id: "reply", at: 2, fields: ["replyRootId": "root"])
        let other = try TimelineTestFixtures.message(id: "other", at: 3, fields: ["replyRootId": "elsewhere"])
        let page = try TimelineTestFixtures.page([root, reply, other])
        let source = ScriptedTimelineSource(pages: [.success(page), .success(page)])
        let chat = ConversationTimelineModel(chatID: "chat", currentUserID: 1, isGroupChat: true, source: source, messageStore: source.store)
        let thread = ConversationTimelineModel(chatID: "chat", currentUserID: 1, isGroupChat: true, source: source, messageStore: source.store, threadID: "root")
        await chat.open()
        await thread.open()
        source.store.apply(.message(try TimelineTestFixtures.message(id: "reply2", at: 4, fields: ["replyRootId": "root"])))
        source.store.apply(.threadUpdate(.init(threadRootId: "root", chatId: "chat", lastReplyAt: root.createdAt, replyCount: 2)))
        XCTAssertEqual(remoteMessages(chat).map(\.id), ["root"])
        XCTAssertEqual(remoteMessages(thread).map(\.id), ["root", "reply", "reply2"])
        XCTAssertEqual(remoteMessages(chat).first?.threadInfo?.replyCount, 2)
        XCTAssertEqual(remoteMessages(thread).first?.message, root.message)
    }

    func testBulkDeletionRedactsReplyPreviewsAndEmptyReactionArrayClearsKnownRecord() async throws {
        let root = try TimelineTestFixtures.message(id: "1", at: 1)
        let preview: [String: Any] = [
            "id": "1", "clientGeneratedId": "client-1", "createdAt": "2026-09-01T00:00:01Z",
            "sender": ["uid": 1, "gender": 0], "messageType": "text", "message": "secret",
            "attachments": [["kind": "image/png"]], "mentions": [], "isDeleted": false,
        ]
        let reply = try TimelineTestFixtures.message(id: "2", at: 2, fields: ["replyToMessage": preview])
        let (model, source, _) = try makeModel(pages: [.success(try TimelineTestFixtures.page([root, reply]))])
        await model.open()
        source.store.apply(.reactionUpdated(.init(messageId: "2", chatId: "chat", reactions: try reactionFixture())))
        XCTAssertEqual(remoteMessages(model).last?.reactions.first?.count, 3)
        source.store.apply(.reactionUpdated(.init(messageId: "2", chatId: "chat", reactions: [])))
        source.store.apply(.messagesBulkDeleted(.init(chatId: "chat", messageIds: ["1", "missing"])))
        XCTAssertEqual(remoteMessages(model).map(\.id), ["1", "2"])
        XCTAssertTrue(try XCTUnwrap(remoteMessages(model).first).isDeleted)
        let quoted = try XCTUnwrap(remoteMessages(model).last?.replyToMessage)
        XCTAssertEqual(quoted.id, "1")
        XCTAssertTrue(quoted.isDeleted)
        XCTAssertNil(quoted.message)
        XCTAssertTrue(quoted.attachments.isEmpty)
        XCTAssertTrue(try XCTUnwrap(remoteMessages(model).last).reactions.isEmpty)
        source.store.apply(.messageUpdated(reply))
        XCTAssertNil(remoteMessages(model).last?.replyToMessage?.message, "A later WS record cannot restore a deleted quote")
    }

    func testReopenSameModelAlwaysFetchesAndDiscardsPreviousRemoteRows() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try livePage(ids: 1 ... 2)), .success(try livePage(ids: 3 ... 3)),
        ])
        await model.open()
        model.close()
        source.store.apply(.message(try TimelineTestFixtures.message(id: "4", at: 4)))
        await model.open()
        XCTAssertEqual(source.queries.count, 2)
        XCTAssertEqual(remoteMessages(model).map(\.id), ["3"])
    }

    func testRecoveryRetainsVisibleRowsThenReplaysAroundAnchorWithoutJumping() async throws {
        let old = try TimelineTestFixtures.message(id: "11", at: 11, text: "old")
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 10 ... 12, newerCursor: "12")),
            .success(try TimelineTestFixtures.page([old], olderCursor: "11", newerCursor: "11")),
        ])
        await model.open()
        model.userScrollBegan()
        let anchorIndex = try XCTUnwrap(model.rows.firstIndex { $0.messageID == "11" })
        model.viewportDidChange(.init(firstVisibleIndex: anchorIndex, lastVisibleIndex: anchorIndex, distanceToTop: 5_000, distanceToBottom: 5_000, height: 400), reason: .user, revision: model.updates.value.revision)
        source.holdNextRequest()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.waitUntilHeld()
        XCTAssertEqual(source.queries.last?.around, "11")
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(remoteMessages(model).map(\.id), ["10", "11", "12"])
        source.store.apply(.messageUpdated(try TimelineTestFixtures.message(id: "11", at: 11, text: "new")))
        source.store.apply(.message(try TimelineTestFixtures.message(id: "13", at: 13)))
        source.release()
        await recovering.value
        XCTAssertEqual(remoteMessages(model).map(\.id), ["11"])
        XCTAssertEqual(remoteMessages(model).first?.message, "new")
        XCTAssertEqual(model.state.live.unseenCount, 1)
        XCTAssertFalse(model.state.live.followsLatest)
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .reveal(.message(.clientGenerated("client-11")), animated: false, highlight: false))
    }

    func testRecoveryFailureKeepsRowsAndEmptyRetryDoesNotResurrectOldContent() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1 ... 2, newerCursor: "2")),
            .failure(StubError()), .success(try TimelineTestFixtures.page([])),
        ])
        await model.open()
        model.userScrollBegan()
        await model.reconcileAfterReconnect()
        XCTAssertTrue(model.state.reconciliationFailed)
        XCTAssertEqual(remoteMessages(model).map(\.id), ["1", "2"])
        await model.reconcileAfterReconnect()
        XCTAssertFalse(model.state.reconciliationFailed)
        XCTAssertTrue(remoteMessages(model).isEmpty)
        XCTAssertFalse(model.state.live.followsLatest)
    }

    func testNavigationSupersedesSuspendedRecoveryAndCloseInvalidatesInitialResponse() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1 ... 2, newerCursor: "2")),
            .success(try livePage(ids: 1 ... 2)),
            .success(try livePage(ids: 10 ... 11)),
            .success(try livePage(ids: 20 ... 21)),
        ])
        await model.open()
        source.holdNextRequest()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.waitUntilHeld()
        await model.jumpToLiveEdge()
        source.release()
        await recovering.value
        XCTAssertEqual(remoteMessages(model).map(\.id), ["10", "11"])
        model.close()
        source.holdNextRequest()
        let reopening = Task { await model.open() }
        await source.waitUntilHeld()
        model.close()
        source.release()
        await reopening.value
        XCTAssertTrue(remoteMessages(model).isEmpty)
    }

    func testCancellingRecoveryKeepsObservationAliveForForegroundRetry() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try livePage(ids: 1 ... 1)), .success(try livePage(ids: 8 ... 8)),
            .success(try livePage(ids: 3 ... 3)),
        ])
        await model.open()
        source.holdNextRequest()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.waitUntilHeld()
        recovering.cancel()
        await source.drain()
        source.store.apply(.message(try TimelineTestFixtures.message(id: "2", at: 2)))
        source.release()
        await recovering.value
        XCTAssertEqual(remoteMessages(model).map(\.id), ["1", "2"])
        await model.reconcileAfterReconnect()
        XCTAssertEqual(remoteMessages(model).map(\.id), ["3"])
    }

    private func remoteMessages(_ model: ConversationTimelineModel) -> [MessageResponse] {
        model.rows.compactMap {
            guard case .message(let row) = $0 else { return nil }
            return row.entry.remoteMessage
        }
    }

    private func pending(id: String) -> PendingOutgoingMessage {
        .init(chatID: "chat", clientGeneratedID: id, body: .init(messageType: .text, clientGeneratedId: id, message: "sending"),
              enqueuedAt: TimelineTestFixtures.date(second: 0), senderID: 1, state: .sending)
    }

    private func reactionFixture() throws -> [ReactionSummary] {
        try JSONDecoder().decode([ReactionSummary].self, from: Data(
            "[{\"emoji\":\"like\",\"count\":3,\"reactors\":[{\"uid\":2}]}]".utf8
        ))
    }

    // MARK: Helpers

    private func makeModel(
        pages: [Result<ListMessagesResponse, Error>]
    ) throws -> (ConversationTimelineModel, ScriptedTimelineSource, CurrentValueSubject<[TimelineHostSnapshot], Never>) {
        let source = ScriptedTimelineSource(pages: pages)
        let model = ConversationTimelineModel(
            chatID: "chat",
            currentUserID: 1,
            isGroupChat: true,
            source: source,
            messageStore: source.store
        )
        let updates = CurrentValueSubject<[TimelineHostSnapshot], Never>([])
        model.updates.sink { updates.value.append($0) }.store(in: &cancellables)
        return (model, source, updates)
    }

    private func livePage(ids: ClosedRange<Int>) throws -> ListMessagesResponse {
        try historyPage(ids: ids, olderCursor: nil, newerCursor: nil)
    }

    private func historyPage(ids: ClosedRange<Int>, olderCursor: String? = nil, newerCursor: String?) throws -> ListMessagesResponse {
        try TimelineTestFixtures.page(
            ids.map { try TimelineTestFixtures.message(id: "\($0)", senderID: Int32($0 % 2 + 1), at: $0 % 60, minute: $0 / 60) },
            olderCursor: olderCursor,
            newerCursor: newerCursor
        )
    }
}

private struct StubError: Error {}

@MainActor
private final class ScriptedTimelineSource: TimelineMessageSource {
    let store = ConversationMessageStore()
    private(set) var queries: [ListMessagesQuery] = []
    private var pages: [Result<ListMessagesResponse, Error>]
    private var shouldHoldNextRequest = false
    private var heldResponse: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    init(pages: [Result<ListMessagesResponse, Error>]) {
        self.pages = pages
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        queries.append(query)
        precondition(!pages.isEmpty, "Unscripted fetch: \(query)")
        let result = pages.removeFirst()
        if shouldHoldNextRequest {
            shouldHoldNextRequest = false
            await withCheckedContinuation { continuation in
                heldResponse = continuation
                heldWaiter?.resume()
                heldWaiter = nil
            }
        } else { await Task.yield() }
        return try result.get()
    }

    func holdNextRequest() { shouldHoldNextRequest = true }

    func waitUntilHeld() async {
        guard heldResponse == nil else { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func release() {
        heldResponse?.resume()
        heldResponse = nil
    }

    /// Lets detached edge-load tasks run to completion.
    func drain() async {
        for _ in 0 ..< 8 { await Task.yield() }
    }
}
