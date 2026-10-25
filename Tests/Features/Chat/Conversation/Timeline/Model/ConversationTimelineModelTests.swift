import ChahuaAPI
import Combine
import XCTest

@testable import chahua_apple

@MainActor
final class ConversationTimelineModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func testRevokedReceiptCannotBeRestoredByLateResponse() async throws {
        let source = ScriptedTimelineSource(pages: [.success(try livePage(ids: 1...2))])
        var release: CheckedContinuation<MessageID?, Never>?
        var revoked = false
        let started = expectation(description: "Original receipt request suspended")
        let denied = expectation(description: "Privacy refresh denied")
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store,
            fetchReadReceipt: { _ in
                if revoked {
                    denied.fulfill()
                    return nil
                }
                return await withCheckedContinuation {
                    release = $0
                    started.fulfill()
                }
            })
        await model.open()
        model.setReadTrackingActive(true)
        await fulfillment(of: [started], timeout: 2)
        revoked = true
        model.refreshReadReceipt(clear: true)
        await fulfillment(of: [denied], timeout: 2)
        release?.resume(returning: MessageID(2))
        await source.drain()
        XCTAssertFalse(
            model.rows.contains {
                if case .message(let row) = $0 { return row.isRead }
                return false
            })
        model.close()
    }

    func testThreadReceiptsUseSeparateRootCursorAndRevokeOnPrivacyChange() async throws {
        let messages = [
            try TimelineTestFixtures.message(id: 10, at: 1),
            try TimelineTestFixtures.message(id: 11, at: 2, fields: ["replyRootId": "10"]),
            try TimelineTestFixtures.message(id: 12, at: 3, fields: ["replyRootId": "10"]),
            try TimelineTestFixtures.message(
                id: 13, senderID: 2, at: 4, fields: ["replyRootId": "10"]),
            try TimelineTestFixtures.message(id: 14, at: 5, fields: ["replyRootId": "10"]),
        ]
        let source = ScriptedTimelineSource(pages: [
            .success(try TimelineTestFixtures.page(messages))
        ])
        var hidden = false
        var failedRequests: XCTestExpectation?
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store, threadID: "10",
            fetchReadReceipt: { threadID in
                if hidden {
                    failedRequests?.fulfill()
                    throw StubError()
                }
                return MessageID(threadID == nil ? 9 : 13)
            })
        await model.open()
        let received = expectation(description: "Thread receipt published")
        model.updates.first { snapshot in
            snapshot.rows.contains {
                if case .message(let row) = $0 { return row.isRead }
                return false
            }
        }.sink { _ in received.fulfill() }.store(in: &cancellables)
        model.setReadTrackingActive(true)
        await fulfillment(of: [received], timeout: 2)
        let readIDs = model.rows.compactMap { row -> MessageID? in
            guard case .message(let message) = row, message.isRead else { return nil }
            return message.entry.serverID
        }
        XCTAssertEqual(readIDs, [MessageID(11), MessageID(12)])

        hidden = true
        let ordinaryFailure = expectation(description: "Both refresh requests fail")
        ordinaryFailure.expectedFulfillmentCount = 2
        failedRequests = ordinaryFailure
        model.refreshReadReceipt()
        await fulfillment(of: [ordinaryFailure], timeout: 2)
        XCTAssertTrue(
            model.rows.contains {
                if case .message(let row) = $0 { return row.isRead }
                return false
            })
        let privacyFailure = expectation(description: "Both privacy refresh requests fail")
        privacyFailure.expectedFulfillmentCount = 2
        failedRequests = privacyFailure
        model.refreshReadReceipt(clear: true)
        XCTAssertFalse(
            model.rows.contains {
                if case .message(let row) = $0 { return row.isRead }
                return false
            })
        await fulfillment(of: [privacyFailure], timeout: 2)
        XCTAssertFalse(
            model.rows.contains {
                if case .message(let row) = $0 { return row.isRead }
                return false
            })
        model.close()
    }

    func testReplyJumpReusesLoadedTargetAndLoadsMissingHistory() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try livePage(ids: 10...12)),
            .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
        ])
        await model.open()
        await model.jumpToMessage(MessageID(11))
        XCTAssertEqual(source.queries.count, 1)
        XCTAssertFalse(model.state.live.followsLatest)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.message(.clientGenerated("client-11")), animated: true, highlight: true))
        await model.jumpToMessage(MessageID(2))
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1), MessageID(2), MessageID(3)])
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.message(.clientGenerated("client-2")), animated: false, highlight: true))
    }

    func testFailedReplyJumpKeepsHistoryAndCanBeRetried() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try livePage(ids: 10...12)), .failure(StubError()),
            .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
        ])
        await model.open()
        await model.jumpToMessage(MessageID(2))
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(model.state.repositionFailure, .message(MessageID(2)))
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(10), MessageID(11), MessageID(12)])
        await model.jumpToMessage(MessageID(2))
        XCTAssertNil(model.state.repositionFailure)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1), MessageID(2), MessageID(3)])
    }

    func testLoadedReplyJumpSupersedesAnInFlightHistoryJump() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try livePage(ids: 10...12)),
            .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
        ])
        await model.open()
        source.holdNextRequest()
        let oldJump = Task { await model.jumpToMessage(MessageID(2)) }
        await source.waitUntilHeld()
        await model.jumpToMessage(MessageID(11))
        source.release()
        let superseded = await oldJump.value
        XCTAssertEqual(superseded, .failed)
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(10), MessageID(11), MessageID(12)])
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.message(.clientGenerated("client-11")), animated: true, highlight: true))
    }

    func testInitialLoadPublishesBottomResetWithRemoteRows() async throws {
        let (model, _, updates) = try makeModel(pages: [.success(try livePage(ids: 1...2))])

        await model.loadInitial()

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertTrue(model.isAtLiveEdge)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertEqual(updates.value.last?.pendingScroll?.intent, .bottom(animated: false))
    }

    func testInitialLoadFailureIsRetryable() async throws {
        let (model, _, _) = try makeModel(pages: [
            .failure(StubError()), .success(try livePage(ids: 1...1)),
        ])

        await model.loadInitial()
        XCTAssertEqual(model.state.content, .initialLoadFailed)

        await model.retryInitial()
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1)])
    }

    func testRestoredFailedRowsRemainVisibleWhileInitialHistoryLoadsAndFails() async throws {
        let source = ScriptedTimelineSource(pages: [.failure(StubError())])
        var failed = pending(id: "restored")
        failed.state = .failed
        source.store.replacePending(chatID: "chat", with: [failed])
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
            messageStore: source.store)
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
        XCTAssertEqual(
            Set(model.rows.compactMap(\.stableMessageKey)),
            [.clientGenerated("restored"), .clientGenerated("new")])
    }

    func testAtomicAcknowledgementDuringInitialLoadingSurvivesFailureAndRetry() async throws {
        let acknowledged = try TimelineTestFixtures.message(
            id: 1, at: 1, clientGeneratedID: "send")
        let (model, source, _) = try makeModel(pages: [
            .failure(StubError()), .success(try TimelineTestFixtures.page([acknowledged])),
        ])
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])
        source.holdNextRequest()
        let loading = Task { await model.open() }
        await source.waitUntilHeld()
        var visibleKeys: [[ConversationMessageStableKey]] = []
        let observation = model.updates.sink {
            visibleKeys.append($0.rows.compactMap(\.stableMessageKey))
        }
        defer { observation.cancel() }

        source.store.replacePending(chatID: "chat", with: [], acknowledging: acknowledged)
        XCTAssertEqual(model.state.content, .loadingInitial)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
        source.store.apply(
            .message(try TimelineTestFixtures.message(id: 2, senderID: 2, at: 2)))
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(1)],
            "Only matched acknowledgements are exposed before history succeeds")
        source.release()
        await loading.value
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])

        source.holdNextRequest()
        let retrying = Task { await model.retryInitial() }
        await source.waitUntilHeld()
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
        source.release()
        await retrying.value
        XCTAssertEqual(
            model.rows.filter { $0.stableMessageKey == .clientGenerated("send") }.count, 1)
        XCTAssertTrue(
            visibleKeys.allSatisfy { $0.filter { $0 == .clientGenerated("send") }.count == 1 })
    }

    func testAcknowledgementAfterInitialFailureRemainsDeliveredUntilSnapshot() async throws {
        let acknowledged = try TimelineTestFixtures.message(
            id: 1, at: 1, clientGeneratedID: "send")
        let (model, source, _) = try makeModel(pages: [
            .failure(StubError()), .success(try TimelineTestFixtures.page([acknowledged])),
        ])
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])
        await model.open()
        source.store.replacePending(chatID: "chat", with: [], acknowledging: acknowledged)
        source.store.replacePending(chatID: "chat", with: [])
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
        await model.retryInitial()
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), [.clientGenerated("send")])
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
    }

    func testRevealAfterDurableEnqueueReusesNearbyLiveWindowWithoutWritingAgain() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1...2))])
        await model.open()
        model.userScrollBegan()
        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: model.rows.count - 1, distanceToTop: 5_000,
                distanceToBottom: 100, height: 400), reason: .user,
            revision: model.updates.value.revision)
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])

        model.revealLatestAfterSend()

        XCTAssertEqual(source.queries.count, 1)
        XCTAssertEqual(
            model.rows.filter { $0.stableMessageKey == .clientGenerated("send") }.count, 1)
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: false))
        XCTAssertFalse(model.updates.value.animateFollowing)
        XCTAssertTrue(model.state.live.followsLatest)
    }

    func testScheduledRevealAfterSendDoesNotWaitForLiveEdgeFetch() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 1...3)),
        ])
        await model.loadInitial()
        XCTAssertFalse(model.isAtLiveEdge)
        source.holdNextRequest()

        model.revealLatestAfterSend()
        await source.waitUntilHeld()

        XCTAssertEqual(source.queries.count, 2)
        XCTAssertEqual(model.state.content, .repositioning(.liveEdge))
        source.release()
        await source.drain()
        XCTAssertEqual(model.state.content, .ready)
    }

    func testLiveMessageOffLiveEdgeIsDeferredAndMakesJumpAvailable() async throws {
        let (model, source, updates) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2)))
        ])
        await model.loadInitial()
        XCTAssertFalse(model.isAtLiveEdge)
        let updatesBefore = updates.value.count

        source.store.apply(.message(try TimelineTestFixtures.message(id: 3, senderID: 2, at: 3)))

        XCTAssertTrue(model.showsJumpToLatest)
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)],
            "history view must not render the deferred message")
        XCTAssertEqual(
            updates.value.count, updatesBefore,
            "A deferred arrival does not republish timeline rows.")
    }

    func testLiveMessageAtPinnedLiveEdgeAppendsAndFollows() async throws {
        let (model, source, updates) = try makeModel(pages: [.success(try livePage(ids: 1...1))])
        await model.loadInitial()

        source.store.apply(.message(try TimelineTestFixtures.message(id: 2, senderID: 2, at: 2)))

        XCTAssertFalse(model.showsJumpToLatest)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertTrue(updates.value.last?.animateFollowing == true)
    }

    func testLiveMessageAtUnpinnedLiveEdgeRendersWithoutFollowing() async throws {
        let (model, source, updates) = try makeModel(pages: [.success(try livePage(ids: 1...1))])
        await model.loadInitial()
        model.scrollRequestDidFinish(id: model.updates.value.pendingScroll!.id)
        model.userScrollBegan()
        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 0, distanceToTop: 0, distanceToBottom: 500,
                height: 400), reason: .user, revision: model.updates.value.revision)
        XCTAssertFalse(model.state.live.isPinnedToBottom)
        XCTAssertTrue(model.showsJumpToLatest, "Moving away from the bottom reveals the shortcut.")

        source.store.apply(.message(try TimelineTestFixtures.message(id: 2, senderID: 2, at: 2)))

        XCTAssertFalse(updates.value.last?.animateFollowing == true)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertNil(updates.value.last?.pendingScroll)
    }

    func testPinnedViewportDoesNotClearUnreadBeforeServerConfirmation() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1...1))])
        await model.loadInitial()
        model.updateReadState(unreadCount: 1, lastReadMessageID: MessageID(1))
        model.scrollRequestDidFinish(id: model.updates.value.pendingScroll!.id)
        model.userScrollBegan()
        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 0, distanceToTop: 0, distanceToBottom: 500,
                height: 400), reason: .user, revision: model.updates.value.revision)
        source.store.apply(.message(try TimelineTestFixtures.message(id: 2, senderID: 2, at: 2)))
        XCTAssertEqual(model.jumpUnreadCount, 1)

        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0, distanceToBottom: 0,
                height: 400), reason: .user, revision: model.updates.value.revision)

        XCTAssertTrue(model.state.live.isPinnedToBottom)
        XCTAssertFalse(
            model.showsJumpToLatest, "A stale unread count cannot keep the shortcut on screen.")
        XCTAssertEqual(
            model.jumpUnreadCount, 1,
            "Reaching bottom alone cannot clear authoritative unread state.")
    }

    func testJumpToLiveEdgeFromHistoryReplaysDeferredArrivalNewerThanServerPage() async throws {
        let (model, source, updates) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 98...99)),
        ])
        await model.loadInitial()
        // Newer than the server page's newest ID (99) and absent from that page.
        source.store.apply(
            .message(try TimelineTestFixtures.message(id: 100, senderID: 2, at: 40, minute: 1)))
        XCTAssertTrue(model.showsJumpToLatest)

        await model.jumpToLiveEdge()

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertNil(model.state.repositionFailure)
        XCTAssertTrue(model.isAtLiveEdge)
        XCTAssertTrue(model.state.live.followsLatest)
        XCTAssertNil(source.queries.last?.after)
        XCTAssertNil(source.queries.last?.before)
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99), MessageID(100)])
        XCTAssertEqual(updates.value.last?.pendingScroll?.intent, .bottom(animated: false))
    }

    func testJumpToLiveEdgeDropsDeferredArrivalOlderThanNewWindow() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 98...99)),
        ])
        await model.loadInitial()
        // Older than ID 98: replaying it would render above a history gap.
        source.store.apply(.message(try TimelineTestFixtures.message(id: 3, senderID: 2, at: 3)))

        await model.jumpToLiveEdge()

        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99)],
            "stale deferred entry must not be injected above the gap")
    }

    func testInitialOpenUsesHTTPRatherThanEventsFromAPriorScreen() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 98...99))])
        source.store.apply(.message(try TimelineTestFixtures.message(id: 100, at: 40, minute: 1)))
        await model.open()
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99)])
    }

    func testLatestSnapshotReconcilesDeferredCreatesByIdentityAndRetainsEqualTimeArrivals()
        async throws
    {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 98...99)),
        ])
        await model.loadInitial()
        source.store.apply(
            .message(try TimelineTestFixtures.message(id: 99, senderID: 2, at: 39, minute: 1)))
        source.store.apply(
            .message(try TimelineTestFixtures.message(id: 100, senderID: 2, at: 39, minute: 1)))
        await model.jumpToLiveEdge()
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99), MessageID(100)])
    }

    func testJumpToLiveEdgeFailureIsAnOverlayThatKeepsPagingAlive() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(
                try historyPage(
                    ids: 10...11, olderCursor: MessageID(10), newerCursor: MessageID(11))),
            .failure(StubError()),
            .success(
                try historyPage(ids: 8...9, olderCursor: MessageID(8), newerCursor: MessageID(9))),
        ])
        await model.loadInitial()

        await model.jumpToLiveEdge()

        XCTAssertEqual(model.state.content, .ready, "failure must not park the lifecycle")
        XCTAssertEqual(model.state.repositionFailure, .liveEdge)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(10), MessageID(11)])

        // Paging is still live while the failure banner is showing.
        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0,
                distanceToBottom: 5_000, height: 400), reason: .user,
            revision: model.updates.value.revision)
        await source.drain()
        XCTAssertEqual(source.queries.last?.before, MessageID(10))
        XCTAssertEqual(
            model.rows.compactMap(\.messageID),
            [MessageID(8), MessageID(9), MessageID(10), MessageID(11)])
        XCTAssertEqual(model.state.repositionFailure, .liveEdge, "paging does not clear the banner")

        model.dismissRepositionFailure()
        XCTAssertNil(model.state.repositionFailure)
    }

    func testInitialLoadAroundMissingTargetSurfacesOverlayAndStaysReady() async throws {
        let (model, _, updates) = try makeModel(pages: [.success(try livePage(ids: 1...2))])

        await model.loadInitial(position: .message(MessageID(404)))

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(model.state.repositionFailure, .message(MessageID(404)))
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertEqual(updates.value.last?.pendingScroll?.intent, .bottom(animated: false))
    }

    func testOlderEdgeFailureIsSurfacedAndRetryable() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 10...11, olderCursor: MessageID(10), newerCursor: nil)),
            .failure(StubError()),
            .success(
                try historyPage(ids: 8...9, olderCursor: MessageID(8), newerCursor: MessageID(9))),
        ])
        await model.loadInitial()

        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0, distanceToBottom: 0,
                height: 400), reason: .user, revision: model.updates.value.revision)
        await source.drain()
        XCTAssertEqual(model.state.older, .failed)
        XCTAssertEqual(source.queries.last?.before, MessageID(10))

        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0, distanceToBottom: 0,
                height: 400), reason: .user, revision: model.updates.value.revision)
        XCTAssertEqual(source.queries.count, 2, "failed edge must not refetch until retried")

        model.retryOlder()
        await source.drain()
        XCTAssertEqual(model.state.older, .idle)
        XCTAssertEqual(
            model.rows.compactMap(\.messageID),
            [MessageID(8), MessageID(9), MessageID(10), MessageID(11)])
    }

    func testInitialSnapshotReplaysEditReactionAndDeletionBeforePublishing() async throws {
        let old = try TimelineTestFixtures.message(
            id: 1, at: 1, text: "old",
            fields: [
                "hasAttachments": true,
                "attachments": [
                    [
                        "id": "file", "url": "/file", "kind": "image/png", "size": 1,
                        "fileName": "file.png",
                    ]
                ],
            ])
        let edited = try TimelineTestFixtures.message(id: 1, at: 1, text: "new")
        let (model, source, updates) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([old]))
        ])
        source.holdNextRequest()
        let loading = Task { await model.open() }
        await source.waitUntilHeld()
        source.store.apply(.messageUpdated(edited))
        source.store.apply(
            .reactionUpdated(
                .init(messageId: MessageID(1), chatId: "chat", reactions: try reactionFixture())))
        source.store.apply(.messageDeleted(edited.redactedForDeletion()))
        source.release()
        await loading.value

        XCTAssertTrue(
            model.rows.isEmpty, "Deleted messages leave neither bubbles nor date separators")
        XCTAssertFalse(
            updates.value.contains { snapshot in
                snapshot.rows.contains { row in
                    if case .message(let row) = row { return row.entry.text == "old" }
                    return false
                }
            }, "No intermediate HTTP baseline may reach a native host")
    }

    func testOlderPageReplaysUnknownEditWithoutLosingRowsOutsideFetchedScope() async throws {
        let old = try TimelineTestFixtures.message(id: 1, at: 1, text: "old")
        let edited = try TimelineTestFixtures.message(id: 1, at: 1, text: "new")
        let (model, source, _) = try makeModel(pages: [
            .success(
                try historyPage(
                    ids: 10...11, olderCursor: MessageID(10), newerCursor: MessageID(11))),
            .success(try TimelineTestFixtures.page([old])),
        ])
        await model.loadInitial()
        source.holdNextRequest()
        model.retryOlder()
        await source.waitUntilHeld()
        source.store.apply(.messageUpdated(edited))
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(10), MessageID(11)],
            "An unknown edit is not a create")
        source.release()
        await source.drain()
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(1), MessageID(10), MessageID(11)])
        XCTAssertEqual(remoteMessages(model).first?.message, "new")
    }

    func testLaterHTTPMayReplaceAnEventReceivedBeforeThatRequest() async throws {
        let old = try TimelineTestFixtures.message(id: 1, at: 1, text: "old")
        let new = try TimelineTestFixtures.message(id: 1, at: 1, text: "new")
        let authoritative = try TimelineTestFixtures.message(id: 1, at: 1, text: "authoritative")
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

    func testInitialCreateAndHTTPAcknowledgementConvergeWithoutFollowingOrDuplicateRows()
        async throws
    {
        let acknowledged = try TimelineTestFixtures.message(
            id: 1, at: 1, clientGeneratedID: "send")
        for websocketFirst in [true, false] {
            let (model, source, updates) = try makeModel(pages: [
                .success(try TimelineTestFixtures.page([acknowledged]))
            ])
            source.store.enqueue(pending(id: "send"))
            source.holdNextRequest()
            let loading = Task { await model.open() }
            await source.waitUntilHeld()
            if websocketFirst { source.store.apply(.message(acknowledged)) }
            source.release()
            await loading.value
            if !websocketFirst { source.store.apply(.message(acknowledged)) }
            XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), [.clientGenerated("send")])
            XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
            XCTAssertFalse(updates.value.contains { $0.animateFollowing })
        }
    }

    func testDuplicateCreateAndLateAcknowledgementCannotUndoEditOrDelete() async throws {
        let created = try TimelineTestFixtures.message(
            id: 1, at: 1, text: "old", clientGeneratedID: "send")
        let edited = try TimelineTestFixtures.message(
            id: 1, at: 1, text: "new", clientGeneratedID: "send")
        let (model, source, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([])),
            .success(try TimelineTestFixtures.page([created])),
            .success(try TimelineTestFixtures.page([created])),
        ])
        await model.open()
        source.store.enqueue(pending(id: "send"))
        var visibleKeys: [[ConversationMessageStableKey]] = []
        let observation = model.updates.sink {
            visibleKeys.append($0.rows.compactMap(\.stableMessageKey))
        }
        defer { observation.cancel() }
        source.store.apply(.message(created))
        source.store.apply(.messageUpdated(edited))
        source.store.apply(.message(created))
        source.store.acknowledge(created)
        XCTAssertEqual(remoteMessages(model).map(\.message), ["new"])
        XCTAssertTrue(visibleKeys.allSatisfy { $0 == [.clientGenerated("send")] })
        source.store.apply(.messageDeleted(edited.redactedForDeletion()))
        XCTAssertTrue(model.rows.isEmpty)
        source.store.apply(.message(created))
        source.store.acknowledge(created)
        source.store.apply(.messageUpdated(edited))
        source.store.apply(
            .reactionUpdated(
                .init(messageId: MessageID(1), chatId: "chat", reactions: try reactionFixture())))
        XCTAssertTrue(
            model.rows.isEmpty, "Late events and acknowledgements must not restore deleted rows")
        await model.reconcileAfterReconnect()
        XCTAssertTrue(model.rows.isEmpty, "A stale HTTP snapshot must not restore a deleted row")
        await model.jumpToMessage(MessageID(1))
        XCTAssertEqual(model.state.repositionFailure, .message(MessageID(1)))
        XCTAssertTrue(model.rows.isEmpty, "A reply jump cannot target a removed bubble")
    }

    func testCanonicalAudioPublicationRefreshesAcknowledgementWithoutUndoingLaterState()
        async throws
    {
        let uploaded = try TimelineTestFixtures.message(
            id: 1, at: 1, type: .audio, clientGeneratedID: "send",
            fields: [
                "message": NSNull(), "hasAttachments": true,
                "attachments": [
                    [
                        "id": "upload", "url": "https://media.example/voice.m4a",
                        "kind": "audio/mp4",
                        "size": 1200, "fileName": "voice.m4a",
                    ]
                ],
            ])
        let published = try TimelineTestFixtures.message(
            id: 1, at: 1, type: .audio, clientGeneratedID: "send",
            fields: [
                "message": NSNull(), "hasAttachments": true,
                "attachments": [
                    [
                        "id": "canonical", "url": "https://media.example/voice.ogg",
                        "kind": "audio/ogg",
                        "size": 900, "fileName": "voice.ogg",
                    ]
                ],
            ])
        let (model, source, _) = try makeModel(pages: [.success(try TimelineTestFixtures.page([]))])
        await model.open()
        source.store.acknowledge(uploaded)
        let reactions = try reactionFixture()
        source.store.apply(
            .reactionUpdated(.init(messageId: MessageID(1), chatId: "chat", reactions: reactions)))
        source.store.apply(.message(published))
        source.store.acknowledge(uploaded)

        let messages = remoteMessages(model)
        XCTAssertEqual(messages.map(\.id), [MessageID(1)])
        XCTAssertEqual(messages.first?.attachments.first?.url, "https://media.example/voice.ogg")
        XCTAssertEqual(messages.first?.reactions, reactions)

        source.store.apply(.messageDeleted(published.redactedForDeletion()))
        source.store.apply(.message(published))
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testTwoModelsHaveIndependentHistoryGapsAndJumpAvailability() async throws {
        let source = ScriptedTimelineSource(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 1...2)),
            .success(try livePage(ids: 3...3)),
        ])
        let historical = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
            messageStore: source.store)
        let latest = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
            messageStore: source.store)
        await historical.open()
        await latest.open()
        let created = try TimelineTestFixtures.message(id: 3, at: 3)
        source.store.apply(.message(created))
        source.store.apply(.message(created))
        source.store.apply(
            .messageUpdated(
                try TimelineTestFixtures.message(id: 1, at: 1, text: "edited in both")))
        source.store.apply(
            .messageDeleted(try TimelineTestFixtures.message(id: 2, at: 2).redactedForDeletion()))
        XCTAssertEqual(remoteMessages(historical).map(\.id), [MessageID(1)])
        XCTAssertEqual(remoteMessages(latest).map(\.id), [MessageID(1), MessageID(3)])
        for model in [historical, latest] {
            XCTAssertEqual(remoteMessages(model).first?.message, "edited in both")
        }
        XCTAssertTrue(historical.showsJumpToLatest)
        XCTAssertFalse(latest.showsJumpToLatest)
        await historical.jumpToLiveEdge()
        XCTAssertEqual(
            remoteMessages(historical).map(\.id), [MessageID(3)],
            "A latest replacement must not bridge the old history gap")
        XCTAssertEqual(remoteMessages(latest).map(\.id), [MessageID(1), MessageID(3)])
    }

    func testDeferredMutationsRemainWindowLocalUntilLatestClosesTheGap() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...1, newerCursor: MessageID(1))),
            .success(try livePage(ids: 2...2)),
        ])
        await model.open()
        let created = try TimelineTestFixtures.message(id: 3, at: 3, text: "old")
        source.store.apply(.message(created))
        source.store.apply(
            .messageUpdated(try TimelineTestFixtures.message(id: 3, at: 3, text: "edited")))
        source.store.apply(.messageDeleted(created.redactedForDeletion()))
        source.store.apply(.message(created))
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
        XCTAssertTrue(model.showsJumpToLatest)
        await model.jumpToLiveEdge()
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(2)])
    }

    func testEmptyLatestSnapshotDiscardsOldDeferredRowsButReplaysInFlightCreate() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...1, newerCursor: MessageID(1))),
            .success(try TimelineTestFixtures.page([])),
        ])
        await model.open()
        source.store.apply(.message(try TimelineTestFixtures.message(id: 2, at: 2)))
        source.holdNextRequest()
        let jumping = Task { await model.jumpToLiveEdge() }
        await source.waitUntilHeld()
        let fresh = try TimelineTestFixtures.message(id: 3, at: 3)
        source.store.apply(.message(fresh))
        source.store.apply(.messageDeleted(fresh.redactedForDeletion()))
        source.release()
        await jumping.value
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testReconnectJoinsInitialOpenInsteadOfStartingACompetingReplacement() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1...1))])
        source.holdNextRequest()
        let opening = Task { await model.open() }
        await source.waitUntilHeld()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.drain()
        source.release()
        await opening.value
        await recovering.value
        XCTAssertEqual(source.queries.count, 1)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
    }

    func testThreadScopeFiltersHTTPAndLiveRepliesWithoutLosingRootMetadata() async throws {
        let root = try TimelineTestFixtures.message(id: 1, at: 1)
        let reply = try TimelineTestFixtures.message(
            id: 2, at: 2, fields: ["replyRootId": "1"])
        let other = try TimelineTestFixtures.message(
            id: 3, at: 3, fields: ["replyRootId": "elsewhere"])
        let page = try TimelineTestFixtures.page([root, reply, other])
        let source = ScriptedTimelineSource(pages: [.success(page), .success(page)])
        let chat = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
            messageStore: source.store)
        let thread = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
            messageStore: source.store, threadID: "1")
        await chat.open()
        await thread.open()
        source.store.apply(
            .message(
                try TimelineTestFixtures.message(
                    id: 4, at: 4, fields: ["replyRootId": "1"])))
        source.store.apply(
            .threadUpdate(
                .init(
                    threadRootId: "1", chatId: "chat", lastReplyAt: root.createdAt, replyCount: 2
                )))
        XCTAssertEqual(remoteMessages(chat).map(\.id), [MessageID(1)])
        XCTAssertEqual(
            remoteMessages(thread).map(\.id), [MessageID(1), MessageID(2), MessageID(4)])
        XCTAssertEqual(remoteMessages(chat).first?.threadInfo?.replyCount, 2)
        XCTAssertEqual(remoteMessages(thread).first?.message, root.message)
    }

    func testBulkDeletionRedactsReplyPreviewsAndEmptyReactionArrayClearsKnownRecord() async throws {
        let root = try TimelineTestFixtures.message(id: 1, at: 1)
        let preview: [String: Any] = [
            "id": "1", "clientGeneratedId": "client-1", "createdAt": "2026-09-01T00:00:01Z",
            "sender": ["uid": 1, "gender": 0], "messageType": "text", "message": "secret",
            "attachments": [["kind": "image/png"]], "mentions": [], "isDeleted": false,
        ]
        let reply = try TimelineTestFixtures.message(
            id: 2, at: 2, fields: ["replyToMessage": preview])
        let (model, source, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([root, reply]))
        ])
        await model.open()
        source.store.apply(
            .reactionUpdated(
                .init(messageId: MessageID(2), chatId: "chat", reactions: try reactionFixture())))
        XCTAssertEqual(remoteMessages(model).last?.reactions.first?.count, 3)
        source.store.apply(
            .reactionUpdated(.init(messageId: MessageID(2), chatId: "chat", reactions: [])))
        source.store.apply(
            .messagesBulkDeleted(.init(chatId: "chat", messageIds: [MessageID(1), MessageID(99)])))
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(2)])
        let quoted = try XCTUnwrap(remoteMessages(model).last?.replyToMessage)
        XCTAssertEqual(quoted.id, MessageID(1))
        XCTAssertTrue(quoted.isDeleted)
        XCTAssertNil(quoted.message)
        XCTAssertTrue(quoted.attachments.isEmpty)
        XCTAssertTrue(try XCTUnwrap(remoteMessages(model).last).reactions.isEmpty)
        source.store.apply(.messageUpdated(reply))
        XCTAssertNil(
            remoteMessages(model).last?.replyToMessage?.message,
            "A later WS record cannot restore a deleted quote")
    }

    func testReopenSameModelAlwaysFetchesAndDiscardsPreviousRemoteRows() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try livePage(ids: 1...2)), .success(try livePage(ids: 3...3)),
        ])
        await model.open()
        model.close()
        source.store.apply(.message(try TimelineTestFixtures.message(id: 4, at: 4)))
        await model.open()
        XCTAssertEqual(source.queries.count, 2)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(3)])
    }

    func testRecoveryRetainsVisibleRowsThenReplaysAroundAnchorWithoutJumping() async throws {
        let old = try TimelineTestFixtures.message(id: 11, at: 11, text: "old")
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 10...12, newerCursor: MessageID(12))),
            .success(
                try TimelineTestFixtures.page(
                    [old], olderCursor: MessageID(11), newerCursor: MessageID(11))),
        ])
        await model.open()
        model.userScrollBegan()
        let anchorIndex = try XCTUnwrap(model.rows.firstIndex { $0.messageID == MessageID(11) })
        model.viewportDidChange(
            .init(
                firstVisibleIndex: anchorIndex, lastVisibleIndex: anchorIndex, distanceToTop: 5_000,
                distanceToBottom: 5_000, height: 400), reason: .user,
            revision: model.updates.value.revision)
        source.holdNextRequest()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.waitUntilHeld()
        XCTAssertEqual(source.queries.last?.around, MessageID(11))
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(10), MessageID(11), MessageID(12)])
        source.store.apply(
            .messageUpdated(try TimelineTestFixtures.message(id: 11, at: 11, text: "new")))
        source.store.apply(.message(try TimelineTestFixtures.message(id: 13, at: 13)))
        source.release()
        await recovering.value
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(11)])
        XCTAssertEqual(remoteMessages(model).first?.message, "new")
        XCTAssertTrue(model.showsJumpToLatest)
        XCTAssertFalse(model.state.live.followsLatest)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.message(.clientGenerated("client-11")), animated: false, highlight: false))
    }

    func testRecoveryFailureKeepsRowsAndEmptyRetryDoesNotResurrectOldContent() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .failure(StubError()), .success(try TimelineTestFixtures.page([])),
        ])
        await model.open()
        model.userScrollBegan()
        await model.reconcileAfterReconnect()
        XCTAssertTrue(model.state.reconciliationFailed)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1), MessageID(2)])
        await model.reconcileAfterReconnect()
        XCTAssertFalse(model.state.reconciliationFailed)
        XCTAssertTrue(remoteMessages(model).isEmpty)
        XCTAssertFalse(model.state.live.followsLatest)
    }

    func testNavigationSupersedesSuspendedRecoveryAndCloseInvalidatesInitialResponse() async throws
    {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 1...2)),
            .success(try livePage(ids: 10...11)),
            .success(try livePage(ids: 20...21)),
        ])
        await model.open()
        source.holdNextRequest()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.waitUntilHeld()
        await model.jumpToLiveEdge()
        source.release()
        await recovering.value
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(10), MessageID(11)])
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
            .success(try livePage(ids: 1...1)), .success(try livePage(ids: 8...8)),
            .success(try livePage(ids: 3...3)),
        ])
        await model.open()
        source.holdNextRequest()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.waitUntilHeld()
        recovering.cancel()
        await source.drain()
        source.store.apply(.message(try TimelineTestFixtures.message(id: 2, at: 2)))
        source.release()
        await recovering.value
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1), MessageID(2)])
        await model.reconcileAfterReconnect()
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(3)])
    }

    func testUnreadEntryAtSettledLiveBottomMarksVisibleMessagesWithoutShowingJump() async throws {
        var reads: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            markRead: { reads.append($0) })
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(1)))
        XCTAssertFalse(model.showsJumpToLatest, "Wait for actual geometry before showing a jump.")
        let request = try XCTUnwrap(model.updates.value.pendingScroll)
        let viewport = TimelineViewport(
            firstVisibleIndex: 0, lastVisibleIndex: model.rows.count - 1,
            distanceToTop: 0, distanceToBottom: 0, height: 600,
            visibleMessageIDs: [MessageID(1), MessageID(2), MessageID(3)])
        model.viewportDidChange(viewport, reason: .layout, revision: model.updates.value.revision)
        XCTAssertFalse(
            model.state.live.followsLatest, "An unfinished reveal still owns navigation.")
        XCTAssertTrue(reads.isEmpty, "Do not mark messages read before the entry scroll settles.")
        model.scrollRequestDidFinish(id: request.id)
        model.viewportDidChange(
            viewport, reason: .programmatic, revision: model.updates.value.revision)
        await source.drain()
        XCTAssertEqual(
            reads, [MessageID(3)], "Entering reads through the last visible message.")
        XCTAssertTrue(model.state.live.isPinnedToBottom)
        XCTAssertTrue(model.state.live.followsLatest)
        XCTAssertFalse(
            model.showsJumpToLatest, "Unread metadata does not mean the viewport is away.")
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(3))
        source.store.apply(.message(try TimelineTestFixtures.message(id: 4, senderID: 2, at: 4)))
        XCTAssertTrue(model.updates.value.animateFollowing)
    }

    func testUnreadEntryAtHistoricalWindowBottomDoesNotFollowLatest() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...3, newerCursor: MessageID(3)))
        ])
        await model.open(position: .unread(after: MessageID(2)))
        model.scrollRequestDidFinish(id: try XCTUnwrap(model.updates.value.pendingScroll).id)
        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: model.rows.count - 1,
                distanceToTop: 0, distanceToBottom: 0, height: 600),
            reason: .programmatic, revision: model.updates.value.revision)
        XCTAssertTrue(model.state.live.isPinnedToBottom)
        XCTAssertFalse(model.state.live.followsLatest)
        XCTAssertFalse(model.isAtLiveEdge)
    }

    func testUnreadEntryRevealsFrozenBoundaryAndPreservesOlderPagination() async throws {
        let read = try TimelineTestFixtures.message(id: 2, at: 2)
        let unread = try TimelineTestFixtures.message(id: 3, at: 3)
        let (model, source, _) = try makeModel(pages: [
            .success(
                try TimelineTestFixtures.page(
                    [read, unread], olderCursor: MessageID(2), newerCursor: nil)),
            .success(try livePage(ids: 1...1)),
        ])
        await model.open(position: .unread(after: read.id))

        XCTAssertEqual(source.queries.first?.around, read.id)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.unreadSeparator, animated: false, highlight: false))
        XCTAssertFalse(model.state.live.followsLatest)
        model.retryOlder()
        await source.drain()
        source.store.apply(.message(try TimelineTestFixtures.message(id: 4, at: 4)))
        let boundary = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows[boundary - 1].messageID, read.id)
        XCTAssertEqual(model.rows[boundary + 1].messageID, unread.id)
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(1), read.id, unread.id, MessageID(4)])
    }

    func testUnreadEntryFetchesBeyondBoundaryAtEndOfAroundPage() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 3...4)),
        ])
        await model.open(position: .unread(after: MessageID(2)))

        XCTAssertEqual(source.queries.map(\.after), [nil, MessageID(2)])
        let boundary = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows[boundary - 1].messageID, MessageID(2))
        XCTAssertEqual(model.rows[boundary + 1].messageID, MessageID(3))
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.unreadSeparator, animated: false, highlight: false))
    }

    func testUnreadWithoutCursorSeeksOldestPageWithoutRetainingEntireHistory() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 5...6, olderCursor: MessageID(5), newerCursor: nil)),
            .success(
                try historyPage(ids: 3...4, olderCursor: MessageID(3), newerCursor: MessageID(4))),
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try historyPage(ids: 3...4, newerCursor: MessageID(4))),
        ])
        await model.open(position: .unread(after: nil))

        XCTAssertEqual(source.queries.map(\.before), [nil, MessageID(5), MessageID(3)])
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertFalse(model.isAtLiveEdge)
        let boundary = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows[boundary + 1].messageID, MessageID(1))
        model.retryNewer()
        await source.drain()
        XCTAssertEqual(source.queries.last?.after, MessageID(2))
        XCTAssertEqual(
            model.rows.compactMap(\.messageID),
            [MessageID(1), MessageID(2), MessageID(3), MessageID(4)])
        XCTAssertEqual(model.rows.firstIndex { $0.id == .unreadSeparator }, boundary)
    }

    func testMissingUnreadTargetUsesAccessibleBeginningWithoutAcknowledgingKnownReadMessages()
        async throws
    {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [
                .success(try historyPage(ids: 3...4, olderCursor: MessageID(3), newerCursor: nil)),
                .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            ], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(99)))

        XCTAssertEqual(source.queries.first?.around, MessageID(99))
        let boundary = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows[boundary + 1].messageID, MessageID(1))
        reportVisible([MessageID(1), MessageID(2)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "A missing cursor is still authoritative read progress.")
        XCTAssertEqual(
            model.rows[boundary + 1].messageID, MessageID(1),
            "Read suppression does not move the entry boundary.")
        model.close()
    }

    func testDeletedUnreadTarget404FallsBackButOtherFailuresRemainRetryable() async throws {
        let (model, source, _) = try makeModel(pages: [
            .failure(APIError.http(status: 404, body: Data())),
            .success(try livePage(ids: 1...2)),
            .failure(StubError()),
        ])
        await model.open(position: .unread(after: MessageID(99)))
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(source.queries.count, 2)
        XCTAssertTrue(model.rows.contains { $0.id == .unreadSeparator })

        await model.open(position: .unread(after: MessageID(100)))
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        XCTAssertEqual(source.queries.count, 3)
    }

    func testEmptyUnreadHistoryAndFullyReadBoundaryDoNotInventSeparator() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([])),
            .success(try livePage(ids: 1...2)),
        ])
        await model.open(position: .unread(after: nil))
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: false))

        await model.open(position: .unread(after: MessageID(2)))
        XCTAssertFalse(model.rows.contains { $0.id == .unreadSeparator })
        XCTAssertTrue(model.state.live.followsLatest)
    }

    func testEmptyAroundResponseDoesNotHideAccessibleUnreadHistory() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([])),
            .success(try historyPage(ids: 3...4, olderCursor: MessageID(3), newerCursor: nil)),
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
        ])
        await model.open(position: .unread(after: MessageID(99)))

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(source.queries.map(\.before), [nil, nil, MessageID(3)])
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.unreadSeparator, animated: false, highlight: false))
    }

    func testUnreadSeekRejectsRepeatedCursorInsteadOfPublishingWrongBeginning() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try historyPage(ids: 3...4, olderCursor: MessageID(3), newerCursor: nil)),
            .success(
                try historyPage(ids: 1...2, olderCursor: MessageID(3), newerCursor: MessageID(2))),
        ])
        await model.open(position: .unread(after: nil))
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        XCTAssertFalse(model.rows.contains { $0.id == .unreadSeparator })
    }

    func testKnownReadCursorOutsideWindowSuppressesEntryAndReentry() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [
                .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
                .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
            ], markRead: { marked.append($0) })
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(99))
        model.setReadTrackingActive(true)
        await model.open(position: .message(MessageID(1)))
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        reportVisible([MessageID(2), MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(marked.isEmpty, "Historical visible rows are already known to be read.")

        model.close()
        model.setReadTrackingActive(true)
        await model.open(position: .message(MessageID(1)))
        reportVisible([MessageID(2), MessageID(3)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "Reentry must not bypass the authoritative cursor.")
        model.close()
    }

    func testNewerRemoteReadCursorSuppressesQueuedDwellDespiteOlderMetadata() async throws {
        var marked: [MessageID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            markRead: { id in
                marked.append(id)
                if id == MessageID(1) { await withCheckedContinuation { releaseFirst = $0 } }
            })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        reportVisible([MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(99))
        releaseFirst?.resume()
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)], "Remote progress invalidates mature queued work.")

        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        reportVisible([MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)],
            "An older snapshot cannot erase authoritative progress outside the window.")
        model.close()
    }

    func testNewerRemoteReadCursorCancelsEntryBeforeItsRequestStarts() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(99))
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "A queued entry must revalidate newer authoritative state.")
        model.close()
    }

    func testThreadRootDoesNotConsumeImmediateReadWithUnknownCursor() async throws {
        var marked: [MessageID] = []
        let root = try TimelineTestFixtures.message(id: 1, at: 1)
        let reply = try TimelineTestFixtures.message(
            id: 2, at: 2, fields: ["replyRootId": "1"])
        let (model, source, _) = try makeModel(
            pages: [.success(try TimelineTestFixtures.page([root, reply]))],
            threadID: "1", markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "The root belongs to the parent conversation's read scope.")
        reportVisible([MessageID(2)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(2)], "The first actual topic reply remains immediate.")
        model.close()
    }

    func testExplicitUnreadResetAllowsRereadingWithoutMovingEntrySeparator() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))], markRead: { marked.append($0) })
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(1)))
        let boundary = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows[boundary + 1].messageID, MessageID(2))
        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(3)])
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(3))

        model.resetReadWatermark(to: MessageID(1))
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(3), MessageID(3)], "Explicit unread permits rereading.")
        XCTAssertEqual(
            model.rows[boundary + 1].messageID, MessageID(2),
            "Read resets do not redefine the frozen entry separator.")

        model.resetReadWatermark(to: nil)
        reportVisible([MessageID(1)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(3), MessageID(3), MessageID(1)],
            "A nil unread cursor permits reading from the beginning again.")
        model.close()
    }

    func testExplicitUnreadResetFencesLateInFlightReadCompletion() async throws {
        var marked: [MessageID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            markRead: { id in
                marked.append(id)
                if marked.count == 1 { await withCheckedContinuation { releaseFirst = $0 } }
            })
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(3)])

        model.resetReadWatermark(to: MessageID(1))
        reportVisible([MessageID(2)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(3)], "The reset cannot overlap an in-flight callback.")
        releaseFirst?.resume()
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(3), MessageID(2)],
            "A pre-reset completion must not restore its superseded watermark.")
        reportVisible([MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(3), MessageID(2), MessageID(3)])
        model.close()
    }

    func testExplicitUnreadResetDuringEntryFetchSupersedesEntryCursor() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))], markRead: { marked.append($0) })
        source.holdNextRequest()
        model.setReadTrackingActive(true)
        let opening = Task { await model.open(position: .unread(after: MessageID(99))) }
        await source.waitUntilHeld()
        model.resetReadWatermark(to: MessageID(1))
        source.release()
        await opening.value
        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(3)],
            "A stale entry snapshot must not undo an intervening unread reset.")
        model.close()
    }

    func testAccountResetPreventsOldModelFromStartingAnotherRead() async throws {
        var marked: [MessageID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2)), .success(try livePage(ids: 1...2))],
            markRead: { id in
                marked.append(id)
                if marked.count == 1 { await withCheckedContinuation { releaseFirst = $0 } }
            })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        source.store.reset()
        releaseFirst?.resume()
        await source.drain()
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(2)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1)], "An old account model cannot resume read tracking.")
        model.close()
    }

    func testExplicitUnreadResetBeforeReentrySupersedesFrozenEntryCursor() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3)), .success(try livePage(ids: 1...3))],
            markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(99)))
        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty)
        model.close()

        model.resetReadWatermark(to: nil)
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(99)))
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)], "A frozen entry cursor cannot undo explicit unread on reentry.")
        model.close()
    }

    func testEntryReadIsImmediateThenDwellUsesStableVisibleCandidate()
        async throws
    {
        var marked: [MessageID] = []
        let messages = [
            try TimelineTestFixtures.message(id: 1, at: 1),
            try TimelineTestFixtures.message(id: 2, at: 2),
            try TimelineTestFixtures.message(id: 3, at: 3),
            try TimelineTestFixtures.message(id: 4, at: 4),
        ]
        let (model, source, _) = try makeModel(
            pages: [.success(try TimelineTestFixtures.page(messages))],
            markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "Opening must not mark an unseen latest message.")
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)], "The first eligible visible candidate bypasses dwell.")
        reportVisible([MessageID(1), MessageID(2)], to: model)
        try await Task.sleep(for: .milliseconds(300))
        reportVisible([MessageID(2), MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            marked, [MessageID(1)],
            "Changing the latest visible message restarts subsequent dwell.")
        reportVisible([MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            marked, [MessageID(1), MessageID(3)],
            "Repeated geometry reports for the same candidate do not restart dwell.")
        reportVisible([MessageID(2)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1), MessageID(3)],
            "Scrolling backwards cannot regress local progress.")
        reportVisible([MessageID(4)], to: model)
        try await Task.sleep(for: .milliseconds(200))
        reportVisible([], to: model)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(
            marked, [MessageID(1), MessageID(3)], "Losing all visible rows cancels dwell.")
        model.close()
    }

    func testReadDwellCancelsForInactiveStaleInvalidAndClosedViewports() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        reportVisible([MessageID(2)], to: model)
        model.setReadTrackingActive(false)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1)])

        model.setReadTrackingActive(true)
        reportVisible([MessageID(2)], to: model, revision: model.updates.value.revision - 1)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)], "Activation requires a fresh matching host viewport.")
        reportVisible([MessageID(2)], to: model)
        source.store.apply(.message(try TimelineTestFixtures.message(id: 3, at: 3)))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)], "Publication invalidates the previous viewport's dwell.")

        reportVisible([MessageID(3)], to: model)
        model.viewportDidChange(.empty, reason: .layout, revision: model.updates.value.revision)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)], "A fully obscured host cancels the previous candidate.")
        reportVisible([MessageID(3)], to: model)
        model.close()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1)])
    }

    func testReadRequestsSerializeAndRevalidateQueuedCandidates() async throws {
        var marked: [MessageID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            markRead: { id in
                marked.append(id)
                if id == MessageID(1) { await withCheckedContinuation { releaseFirst = $0 } }
            })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        reportVisible([MessageID(2)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)], "A mature candidate waits for the in-flight receipt.")
        reportVisible([MessageID(3)], to: model)
        releaseFirst?.resume()
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)], "An obsolete mature candidate must not be sent.")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1), MessageID(3)])
        model.close()
    }

    func testReadFailureRetriesOnlyAfterAnotherStableViewport() async throws {
        var marked: [MessageID] = []
        let (model, _, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...1))],
            markRead: { id in
                marked.append(id)
                if marked.count == 1 { throw StubError() }
            })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(marked, [MessageID(1)], "Failures cannot trigger an automatic retry loop.")
        reportVisible([MessageID(1)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1), MessageID(1)])
        model.close()
    }

    func testExistingWindowScrollCancelsDwellUntilFreshCompletedViewport() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        reportVisible([MessageID(2)], to: model)
        await model.jumpToLiveEdge()
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: true))

        var duringAnimation = TimelineViewport(
            firstVisibleIndex: 0, lastVisibleIndex: model.rows.count - 1, distanceToTop: 0,
            distanceToBottom: 0, height: 400)
        duringAnimation.visibleMessageIDs = [MessageID(2)]
        model.viewportDidChange(
            duringAnimation, reason: .programmatic, revision: model.updates.value.revision)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)],
            "A scroll command invalidates old geometry even without changing rows.")

        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)], "A jump does not reset the entry-only immediate read allowance."
        )
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1), MessageID(3)])
        model.close()
    }

    func testJumpVisibilityTracksActualViewportNotScrollDirectionOrUnreadMetadata() async throws {
        let (model, _, _) = try makeModel(pages: [.success(try livePage(ids: 1...5))])
        await model.open()
        reportVisible([MessageID(4)], to: model)
        model.userScrollBegan()
        reportVisible([MessageID(3)], to: model, reason: .user)
        XCTAssertTrue(model.showsJumpToLatest, "Scrolling upward leaves the live bottom.")
        reportVisible([MessageID(4)], to: model, reason: .layout)
        XCTAssertTrue(model.showsJumpToLatest, "Layout updates retain actual viewport position.")
        reportVisible([MessageID(5)], to: model, reason: .user, distanceToBottom: 0)
        XCTAssertFalse(model.showsJumpToLatest, "The absolute latest edge has nowhere to jump.")
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(3))
        XCTAssertFalse(
            model.showsJumpToLatest, "Unread metadata cannot show a button at the bottom.")
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(5))
        XCTAssertFalse(model.showsJumpToLatest)
    }

    func testJumpUsesChangingReadBoundaryWhileUnreadSeparatorStaysFrozen() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1...5))])
        model.updateReadState(unreadCount: 3, lastReadMessageID: MessageID(2))
        await model.open(position: .unread(after: MessageID(2)))
        reportVisible([MessageID(1)], to: model)
        await model.jumpTowardLatest()
        let firstBoundary = try XCTUnwrap(model.rows.first { $0.messageID == MessageID(2) }?.id)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent, .readBoundary(firstBoundary, animated: true))
        reportVisible([MessageID(2)], to: model)
        await model.jumpTowardLatest()
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent, .bottom(animated: true),
            "A repeat click at the read boundary reaches latest.")

        reportVisible([MessageID(1)], to: model)
        model.updateReadState(unreadCount: 1, lastReadMessageID: MessageID(4))
        await model.jumpTowardLatest()
        let currentBoundary = try XCTUnwrap(model.rows.first { $0.messageID == MessageID(4) }?.id)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .readBoundary(currentBoundary, animated: true))
        let separator = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(
            model.rows[separator + 1].messageID, MessageID(3),
            "Read receipts must not move the entry separator.")
        XCTAssertEqual(model.jumpUnreadCount, 1)
        XCTAssertEqual(source.queries.count, 1, "Loaded read boundaries reuse the native window.")
    }

    func testJumpLoadsUnreadBoundaryThenAbsoluteLatestAcrossDisjointWindows() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try historyPage(ids: 40...42, newerCursor: MessageID(42))),
            .success(try livePage(ids: 98...99)),
        ])
        model.updateReadState(unreadCount: 9, lastReadMessageID: MessageID(41))
        await model.open(position: .message(MessageID(1)))
        reportVisible([MessageID(2)], to: model)
        await model.jumpTowardLatest()
        let boundary = try XCTUnwrap(model.rows.first { $0.messageID == MessageID(41) }?.id)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent, .readBoundary(boundary, animated: false))
        XCTAssertEqual(source.queries.last?.around, MessageID(41))
        reportVisible([MessageID(41)], to: model)
        await model.jumpTowardLatest()
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99)])
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: false))
        XCTAssertTrue(model.isAtLiveEdge)
    }

    func testUnavailableUnreadBoundarySilentlyFallsBackToLatest() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try historyPage(ids: 40...41, newerCursor: MessageID(41))),
            .success(try livePage(ids: 98...99)),
        ])
        model.updateReadState(unreadCount: 3, lastReadMessageID: MessageID(39))
        await model.open(position: .message(MessageID(1)))
        reportVisible([MessageID(2)], to: model)
        await model.jumpTowardLatest()
        XCTAssertEqual(source.queries[1].around, MessageID(39))
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99)])
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: false))
        XCTAssertNil(model.state.repositionFailure)
    }

    func testJumpDoesNotGoBackToUnreadBoundaryBeforeTheVisibleWindow() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 98...99))])
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(50))
        await model.open()
        reportVisible([MessageID(98)], to: model)
        await model.jumpTowardLatest()
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: true))
        XCTAssertEqual(source.queries.count, 1)
    }

    func testUnreadBadgeUsesAuthoritativeMetadataWithoutAddingDeferredArrivals() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...3, newerCursor: MessageID(3)))
        ])
        model.updateReadState(unreadCount: 8, lastReadMessageID: MessageID(1))
        await model.open(position: .unread(after: MessageID(1)))
        reportVisible([MessageID(2)], to: model)
        source.store.apply(.message(try TimelineTestFixtures.message(id: 4, at: 4)))
        XCTAssertEqual(
            model.jumpUnreadCount, 8,
            "The same incoming message is already included in server unread metadata.")
        model.updateReadState(unreadCount: 5, lastReadMessageID: MessageID(2))
        XCTAssertEqual(
            model.jumpUnreadCount, 5, "A read confirmation updates the current conversation badge.")
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(4))
        XCTAssertEqual(model.jumpUnreadCount, 0)
        XCTAssertTrue(
            model.showsJumpToLatest,
            "Deferred live messages keep navigation available without inventing an unread badge.")
    }

    func testHistoricalEntrySuppressesKnownReadsWithoutConsumingImmediateAcknowledgement()
        async throws
    {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...5))], markRead: { marked.append($0) })
        model.updateReadState(unreadCount: 1, lastReadMessageID: MessageID(4))
        model.setReadTrackingActive(true)
        await model.open(position: .message(MessageID(2)))
        reportVisible([MessageID(2)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "Historical entry must not acknowledge already-read rows.")
        reportVisible([MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(marked.isEmpty, "Scrolling behind the known cursor needs no acknowledgement.")
        reportVisible([MessageID(5)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(5)], "The first genuinely unread visible candidate is immediate.")
        model.close()
    }

    func testReactivationKeepsDwellButReopeningAllowsAnotherImmediateVisibleRead() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [
                .success(try livePage(ids: 1...4)),
                .success(try livePage(ids: 1...4)),
            ], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        model.setReadTrackingActive(false)
        model.setReadTrackingActive(true)
        reportVisible([MessageID(2)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)], "Foreground activation is not a new conversation entry.")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1), MessageID(2)])
        model.close()
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1), MessageID(2), MessageID(3)])
        reportVisible([MessageID(4)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1), MessageID(2), MessageID(3)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1), MessageID(2), MessageID(3), MessageID(4)])
        model.close()
    }

    func testCancelledEntryReadDoesNotConsumeFirstValidActiveViewport() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        model.setReadTrackingActive(false)
        model.setReadTrackingActive(true)
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)],
            "Cancellation before sending must leave the fresh visible candidate eligible.")
        model.close()
    }

    func testReopenedEntryImmediateReadWaitsForCancelledInFlightWrite() async throws {
        var marked: [MessageID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let (model, source, _) = try makeModel(
            pages: [
                .success(try livePage(ids: 1...3)),
                .success(try livePage(ids: 1...3)),
            ],
            markRead: { id in
                marked.append(id)
                if id == MessageID(1) { await withCheckedContinuation { releaseFirst = $0 } }
            })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        model.close()
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(2)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)],
            "Cancelled callbacks may ignore cancellation; entries cannot overlap writes.")
        releaseFirst?.resume()
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1), MessageID(2)],
            "The first visible candidate in the new entry needs no dwell after serialization.")
        model.close()
    }

    func testThreadReadMetadataAndImmediateReadStayScopedWhileJumpGoesToLatest() async throws {
        var marked: [MessageID] = []
        let root = try TimelineTestFixtures.message(id: 1, at: 1)
        let reply = try TimelineTestFixtures.message(
            id: 2, at: 2, fields: ["replyRootId": "1"])
        let latest = try TimelineTestFixtures.message(
            id: 3, at: 3, fields: ["replyRootId": "1"])
        let parentOnly = try TimelineTestFixtures.message(id: 4, at: 4)
        let (model, source, _) = try makeModel(
            pages: [.success(try TimelineTestFixtures.page([root, reply, latest, parentOnly]))],
            threadID: "1", markRead: { marked.append($0) }
        )
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(1)))
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "A visible topic root is not topic read progress.")
        reportVisible([MessageID(2)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(2)], "The first unread topic reply is acknowledged immediately.")
        model.updateReadState(unreadCount: 1, lastReadMessageID: MessageID(2))
        reportVisible([MessageID(1)], to: model)
        await model.jumpTowardLatest()
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent, .bottom(animated: true),
            "Thread jump does not stop at the chat-only read boundary.")
        XCTAssertEqual(model.jumpUnreadCount, 1)
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2), MessageID(3)])
        XCTAssertEqual(source.queries.first?.threadID, "1")
        model.close()
    }

    func testActivityResumeReusesLoadedResultsAndReconnectRefreshesScopedStreams() async throws {
        for isGroup in [false, true] {
            for scope in [nil, "1"] as [String?] {
                var mentions: [String?] = []
                var reactions: [String?] = []
                let (model, source, _) = try makeModel(
                    pages: [], threadID: scope, isGroupChat: isGroup,
                    fetchUnreadMentions: {
                        mentions.append($0)
                        return .init(messageIds: [])
                    },
                    fetchUnreadReactions: {
                        reactions.append($0)
                        return .init(messageIds: [], readThrough: "snapshot")
                    })
                model.updateReadState(unreadCount: 0, lastReadMessageID: nil)
                model.setReadTrackingActive(true)
                await source.drain()
                model.setReadTrackingActive(false)
                await source.drain()
                XCTAssertEqual(reactions.count, 1, "Background invalidations do not query.")
                model.setReadTrackingActive(true)
                await source.drain()
                XCTAssertEqual(reactions.count, 1, "Successful foreground data remains fresh.")
                XCTAssertEqual(mentions.count, isGroup ? 1 : 0)
                model.setRealtimeStatus(.reconnecting)
                await source.drain()
                model.setRealtimeStatus(.connected)
                await source.drain()
                XCTAssertEqual(reactions.count, 2)
                XCTAssertTrue(reactions.allSatisfy { $0 == scope })
                XCTAssertEqual(mentions.count, isGroup ? 2 : 0)
                XCTAssertTrue(mentions.allSatisfy { $0 == scope })
                model.close()
            }
        }
    }

    func testReactionSnapshotsAcknowledgeExactBoundaryAndLoopForRemainingUnread() async throws {
        var fetches = 0
        var boundaries: [String?] = []
        let finished = expectation(description: "Second snapshot acknowledged")
        let (model, source, _) = try makeModel(
            pages: [], threadID: "1",
            fetchUnreadReactions: { scope in
                XCTAssertEqual(scope, "1")
                fetches += 1
                return .init(
                    messageIds: [MessageID(fetches == 1 ? 3 : 2), MessageID(3)],
                    readThrough: fetches == 1 ? "opaque-first" : "opaque-second")
            },
            acknowledgeReactions: { scope, boundary in
                XCTAssertEqual(scope, "1")
                boundaries.append(boundary)
                if boundaries.count == 2 { finished.fulfill() }
                return .init(unreadReactions: boundaries.count == 1 ? 1 : 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [finished], timeout: 2)
        await source.drain()
        XCTAssertEqual(boundaries, ["opaque-first", "opaque-second"])
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(model.unreadReactionJumpCount, 2)
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(3))
        XCTAssertEqual(
            model.unreadReactionJumpCount, 2, "Counter clearing retains session targets.")
        model.close()
    }

    func testActivityInvalidationsCoalesceIndependentlyWhileRequestsAreInFlight() async throws {
        let held = expectation(description: "Both streams held")
        held.expectedFulfillmentCount = 2
        let rerun = expectation(description: "Both dirty streams rerun")
        rerun.expectedFulfillmentCount = 2
        var releaseMention: CheckedContinuation<Void, Never>?
        var releaseReaction: CheckedContinuation<Void, Never>?
        var mentions = 0
        var reactions = 0
        var acknowledgements = 0
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            fetchUnreadMentions: { _ in
                mentions += 1
                if mentions == 1 {
                    await withCheckedContinuation {
                        releaseMention = $0
                        held.fulfill()
                    }
                } else {
                    rerun.fulfill()
                }
                return .init(messageIds: [MessageID(2)])
            },
            fetchUnreadReactions: { _ in
                reactions += 1
                if reactions == 1 {
                    await withCheckedContinuation {
                        releaseReaction = $0
                        held.fulfill()
                    }
                } else {
                    rerun.fulfill()
                }
                return .init(messageIds: [MessageID(3)], readThrough: "boundary")
            },
            acknowledgeReactions: { _, _ in
                acknowledgements += 1
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        for _ in 0..<3 { model.refreshUnreadActivity() }
        await model.open()
        XCTAssertEqual(mentions, 1)
        XCTAssertEqual(reactions, 1)
        releaseMention?.resume()
        releaseReaction?.resume()
        await fulfillment(of: [rerun], timeout: 2)
        await source.drain()
        XCTAssertEqual(mentions, 2)
        XCTAssertEqual(reactions, 2)
        XCTAssertEqual(acknowledgements, 2, "History generation changes must not revoke activity.")
        XCTAssertEqual(model.unreadMentionJumpCount, 1)
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        model.close()
    }

    func testFailedReactionGetDoesNotAcknowledgeOrDiscardTargets() async throws {
        var fetches = 0
        var acknowledgements = 0
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _ in
                fetches += 1
                if fetches == 2 { throw StubError() }
                return .init(messageIds: fetches == 1 ? [MessageID(2)] : [], readThrough: "same")
            },
            acknowledgeReactions: { _, _ in
                acknowledgements += 1
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await source.drain()
        model.refreshUnreadActivity(mentions: false)
        await source.drain()
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        model.refreshUnreadActivity(mentions: false)
        await source.drain()
        XCTAssertEqual(acknowledgements, 2)
        XCTAssertEqual(
            model.unreadReactionJumpCount, 1, "An empty snapshot does not replace the queue.")
        model.close()
    }

    func testBackgroundFencesLateReactionGetAndRestoreWaitsForSingleFlight() async throws {
        let held = expectation(description: "GET held")
        let restored = expectation(description: "Restored session acknowledged")
        var release: CheckedContinuation<Void, Never>?
        var fetches = 0
        var boundaries: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _ in
                fetches += 1
                let request = fetches
                if request == 1 {
                    await withCheckedContinuation {
                        release = $0
                        held.fulfill()
                    }
                }
                return .init(messageIds: [MessageID(UInt64(request))], readThrough: "\(request)")
            },
            acknowledgeReactions: { _, boundary in
                boundaries.append(boundary)
                restored.fulfill()
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        model.setReadTrackingActive(false)
        model.setReadTrackingActive(true)
        await source.drain()
        XCTAssertEqual(fetches, 1, "Cancellation-ignoring GETs cannot overlap on restore.")
        release?.resume()
        await fulfillment(of: [restored], timeout: 2)
        await source.drain()
        XCTAssertEqual(boundaries, ["2"], "A backgrounded response must never be acknowledged.")
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        model.close()
    }

    func testForegroundLeaveAcknowledgesSavedThreadScopeWithoutBoundaryAndClearsQueues()
        async throws
    {
        var scopes: [String?] = []
        var boundaries: [String?] = []
        let leave = expectation(description: "Final scoped acknowledgement")
        let (model, source, _) = try makeModel(
            pages: [], threadID: "42",
            fetchUnreadReactions: { _ in
                .init(messageIds: [MessageID(43)], readThrough: "snapshot")
            },
            acknowledgeReactions: { scope, boundary in
                scopes.append(scope)
                boundaries.append(boundary)
                if boundary == nil { leave.fulfill() }
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await source.drain()
        model.close(acknowledgingActivity: true)
        await fulfillment(of: [leave], timeout: 2)
        XCTAssertEqual(scopes, ["42", "42"])
        XCTAssertEqual(boundaries, ["snapshot", nil])
        XCTAssertEqual(model.unreadReactionJumpCount, 0)
    }

    func testAccountResetFencesLateActivityAndCannotReactivateOldAccount() async throws {
        let held = expectation(description: "GET held")
        var release: CheckedContinuation<Void, Never>?
        var fetches = 0
        var acknowledgements = 0
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _ in
                fetches += 1
                await withCheckedContinuation {
                    release = $0
                    held.fulfill()
                }
                return .init(messageIds: [MessageID(2)], readThrough: "old-account")
            },
            acknowledgeReactions: { _, _ in
                acknowledgements += 1
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        source.store.reset()
        release?.resume()
        await source.drain()
        model.setReadTrackingActive(true)
        model.refreshUnreadActivity()
        model.close(acknowledgingActivity: true)
        await source.drain()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertEqual(model.unreadReactionJumpCount, 0)
    }

    func testActivityJumpsOldestFirstSkipMissingAndRetainTransientFailures() async throws {
        let (model, source, _) = try makeModel(
            pages: [
                .success(try livePage(ids: 10...12)),
                .success(try livePage(ids: 10...12)),
                .failure(StubError()),
                .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
            ],
            fetchUnreadMentions: { _ in
                .init(messageIds: [MessageID(11), MessageID(2), MessageID(1), MessageID(2)])
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        XCTAssertEqual(model.unreadMentionJumpCount, 3)
        await model.jumpToNextMention()
        XCTAssertEqual(source.queries.suffix(2).map(\.around), [MessageID(1), MessageID(2)])
        XCTAssertEqual(
            model.unreadMentionJumpCount, 2, "Missing is removed; transient failure stays.")
        await model.jumpToNextMention()
        XCTAssertEqual(model.unreadMentionJumpCount, 1)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.message(.clientGenerated("client-2")), animated: false, highlight: true))
        model.close()
    }

    func testActivityJumpSingleFlightAndRealtimeDeletionPrunesBothQueues() async throws {
        let (model, source, _) = try makeModel(
            pages: [
                .success(try livePage(ids: 10...12)),
                .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
            ],
            fetchUnreadMentions: { _ in .init(messageIds: [MessageID(2), MessageID(11)]) },
            fetchUnreadReactions: { _ in
                .init(messageIds: [MessageID(2), MessageID(11)], readThrough: "snapshot")
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        source.holdNextRequest()
        let jump = Task { await model.jumpToNextMention() }
        await source.waitUntilHeld()
        XCTAssertTrue(model.activityJumpInProgress)
        await model.jumpToNextReaction()
        XCTAssertEqual(source.queries.count, 2)
        source.store.apply(.messageDeleted(try TimelineTestFixtures.message(id: 11, at: 11)))
        XCTAssertEqual(model.unreadMentionJumpCount, 1)
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        source.release()
        await jump.value
        XCTAssertFalse(model.activityJumpInProgress)
        XCTAssertEqual(model.unreadMentionJumpCount, 0)
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        model.close()
    }

    func testInvalidationDuringReactionAckRerunsWithoutOverlappingAcknowledgements() async throws {
        let held = expectation(description: "ACK held")
        let rerun = expectation(description: "Dirty snapshot acknowledged")
        var release: CheckedContinuation<Void, Never>?
        var fetches = 0
        var boundaries: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _ in
                fetches += 1
                return .init(messageIds: [MessageID(UInt64(fetches))], readThrough: "\(fetches)")
            },
            acknowledgeReactions: { _, boundary in
                boundaries.append(boundary)
                if boundaries.count == 1 {
                    await withCheckedContinuation {
                        release = $0
                        held.fulfill()
                    }
                } else {
                    rerun.fulfill()
                }
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        for _ in 0..<3 { model.refreshUnreadActivity(mentions: false) }
        await source.drain()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(boundaries, ["1"])
        release?.resume()
        await fulfillment(of: [rerun], timeout: 2)
        await source.drain()
        XCTAssertEqual(boundaries, ["1", "2"])
        XCTAssertEqual(model.unreadReactionJumpCount, 2)
        model.close()
    }

    func testReopenFencesPendingFinalAckAndBackgroundCloseDoesNotAcknowledge() async throws {
        let held = expectation(description: "Old GET held")
        let restored = expectation(description: "New session acknowledged")
        var release: CheckedContinuation<Void, Never>?
        var fetches = 0
        var boundaries: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _ in
                fetches += 1
                let request = fetches
                if request == 1 {
                    await withCheckedContinuation {
                        release = $0
                        held.fulfill()
                    }
                }
                return .init(messageIds: [MessageID(UInt64(request))], readThrough: "\(request)")
            },
            acknowledgeReactions: { _, boundary in
                boundaries.append(boundary)
                restored.fulfill()
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        model.close(acknowledgingActivity: true)
        model.setReadTrackingActive(true)
        await source.drain()
        XCTAssertEqual(fetches, 1)
        release?.resume()
        await fulfillment(of: [restored], timeout: 2)
        await source.drain()
        XCTAssertEqual(boundaries, ["2"], "The old session's final ACK cannot cross reopen.")
        model.setReadTrackingActive(false)
        model.close(acknowledgingActivity: true)
        await source.drain()
        XCTAssertEqual(boundaries, ["2"], "Closing a background session never acknowledges.")
    }

    func testDeletedCachedTargetsAndHTTPNotFoundAreMissingNotTransientFailures() async throws {
        let deleted = try TimelineTestFixtures.message(id: 1, at: 1).redactedForDeletion()
        let (model, source, _) = try makeModel(
            pages: [
                .success(try TimelineTestFixtures.page([deleted])),
                .failure(APIError.invalidResponse(statusCode: 404)),
            ],
            fetchUnreadMentions: { _ in .init(messageIds: [MessageID(1), MessageID(2)]) })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        XCTAssertEqual(model.unreadMentionJumpCount, 1, "Cached tombstones never become targets.")
        let cached = await model.jumpToMessage(MessageID(1))
        XCTAssertEqual(cached, .missing)
        XCTAssertEqual(source.queries.count, 1)
        await model.jumpToNextMention()
        XCTAssertEqual(
            model.unreadMentionJumpCount, 0, "HTTP 404 drops a confirmed missing target.")
        model.close()
    }

    func testAccountResetAfterCloseCancelsDeferredFinalAcknowledgement() async throws {
        let held = expectation(description: "Old GET held")
        var release: CheckedContinuation<Void, Never>?
        var acknowledgements = 0
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _ in
                await withCheckedContinuation {
                    release = $0
                    held.fulfill()
                }
                return .init(messageIds: [MessageID(2)], readThrough: "old-account")
            },
            acknowledgeReactions: { _, _ in
                acknowledgements += 1
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        model.close(acknowledgingActivity: true)
        source.store.reset()
        release?.resume()
        await source.drain()
        XCTAssertEqual(
            acknowledgements, 0, "Unregistered old models cannot acknowledge a new account.")
    }

    private func reportVisible(
        _ ids: [MessageID], to model: ConversationTimelineModel, revision: Int? = nil,
        reason: TimelineViewportChangeReason = .layout, distanceToBottom: CGFloat = 5_000
    ) {
        if let request = model.updates.value.pendingScroll {
            model.scrollRequestDidFinish(id: request.id)
        }
        let first = ids.first.flatMap { id in model.rows.firstIndex { $0.messageID == id } } ?? 0
        let last =
            ids.last.flatMap { id in model.rows.firstIndex { $0.messageID == id } } ?? model.rows
            .count - 1
        var viewport = TimelineViewport(
            firstVisibleIndex: first, lastVisibleIndex: last, distanceToTop: 5_000,
            distanceToBottom: distanceToBottom, height: 400)
        viewport.visibleMessageIDs = ids
        model.viewportDidChange(
            viewport, reason: reason, revision: revision ?? model.updates.value.revision)
    }

    private func remoteMessages(_ model: ConversationTimelineModel) -> [MessageResponse] {
        model.rows.compactMap {
            guard case .message(let row) = $0 else { return nil }
            return row.entry.remoteMessage
        }
    }

    private func pending(id: String) -> PendingOutgoingMessage {
        .init(
            chatID: "chat", clientGeneratedID: id,
            body: .init(messageType: .text, clientGeneratedId: id, message: "sending"),
            enqueuedAt: TimelineTestFixtures.date(second: 0), senderID: 1, state: .sending)
    }

    private func reactionFixture() throws -> [ReactionSummary] {
        try JSONDecoder().decode(
            [ReactionSummary].self,
            from: Data(
                "[{\"emoji\":\"like\",\"count\":3,\"reactors\":[{\"uid\":2}]}]".utf8
            ))
    }

    // MARK: Helpers

    private func makeModel(
        pages: [Result<ListMessagesResponse, Error>],
        threadID: String? = nil,
        isGroupChat: Bool = true,
        markRead: (@MainActor (MessageID) async throws -> Void)? = nil,
        fetchUnreadMentions: (@MainActor (String?) async throws -> UnreadMentionIDsResponse)? = nil,
        fetchUnreadReactions: (@MainActor (String?) async throws -> UnreadReactionIDsResponse)? =
            nil,
        acknowledgeReactions:
            (@MainActor (String?, String?) async throws -> UnreadReactionsAckResponse)? = nil
    ) throws -> (
        ConversationTimelineModel, ScriptedTimelineSource,
        CurrentValueSubject<[TimelineHostSnapshot], Never>
    ) {
        let source = ScriptedTimelineSource(pages: pages)
        let model = ConversationTimelineModel(
            chatID: "chat",
            currentUserID: 1,
            isGroupChat: isGroupChat,
            source: source,
            messageStore: source.store,
            threadID: threadID,
            markRead: markRead,
            fetchUnreadMentions: fetchUnreadMentions,
            fetchUnreadReactions: fetchUnreadReactions,
            acknowledgeReactions: acknowledgeReactions
        )
        let updates = CurrentValueSubject<[TimelineHostSnapshot], Never>([])
        model.updates.sink { updates.value.append($0) }.store(in: &cancellables)
        return (model, source, updates)
    }

    private func livePage(ids: ClosedRange<Int>) throws -> ListMessagesResponse {
        try historyPage(ids: ids, olderCursor: nil, newerCursor: nil)
    }

    private func historyPage(
        ids: ClosedRange<Int>, olderCursor: MessageID? = nil, newerCursor: MessageID?
    ) throws -> ListMessagesResponse {
        try TimelineTestFixtures.page(
            ids.map {
                try TimelineTestFixtures.message(
                    id: UInt64($0), senderID: Int32($0 % 2 + 1), at: $0 % 60, minute: $0 / 60)
            },
            olderCursor: olderCursor,
            newerCursor: newerCursor
        )
    }
}

private struct StubError: Error {}

@MainActor
final class ScriptedTimelineSource: TimelineMessageSource {
    let store = ConversationMessageStore()
    private(set) var queries: [ListMessagesQuery] = []
    private var pages: [Result<ListMessagesResponse, Error>]
    private var shouldHoldNextRequest = false
    private var heldResponse: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    init(pages: [Result<ListMessagesResponse, Error>]) {
        self.pages = pages
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws
        -> ListMessagesResponse
    {
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
        } else {
            await Task.yield()
        }
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
        for _ in 0..<8 { await Task.yield() }
    }
}
