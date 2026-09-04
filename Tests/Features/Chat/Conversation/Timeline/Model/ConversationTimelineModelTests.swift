import Combine
import XCTest
@testable import chahua_apple
import ChahuaAPI

@MainActor
final class ConversationTimelineModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

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

    func testLiveMessageOffLiveEdgeIsDeferredAndCounted() async throws {
        let (model, source, updates) = try makeModel(pages: [.success(try historyPage(ids: 1 ... 2, newerCursor: "2"))])
        await model.loadInitial()
        XCTAssertFalse(model.isAtLiveEdge)
        let updatesBefore = updates.value.count

        model.receiveLive(try TimelineTestFixtures.message(id: "3", senderID: 2, at: 3))

        XCTAssertEqual(model.state.live.unseenCount, 1)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1", "2"], "history view must not render the deferred message")
        XCTAssertEqual(updates.value.count, updatesBefore, "deferred arrival publishes nothing")
        XCTAssertEqual(source.store.bufferedLiveEventCountForTesting(chatID: "chat"), 1)
    }

    func testLiveMessageAtPinnedLiveEdgeAppendsAndFollows() async throws {
        let (model, source, updates) = try makeModel(pages: [.success(try livePage(ids: 1 ... 1))])
        await model.loadInitial()

        model.receiveLive(try TimelineTestFixtures.message(id: "2", senderID: 2, at: 2))

        XCTAssertEqual(model.state.live.unseenCount, 0)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1", "2"])
        XCTAssertTrue(updates.value.last?.animateFollowing == true)
        XCTAssertEqual(source.store.bufferedLiveEventCountForTesting(chatID: "chat"), 0, "rendered rows are consumed from the deferred buffer")
    }

    func testLiveMessageAtUnpinnedLiveEdgeCountsButStillRendersAndConsumes() async throws {
        let (model, source, updates) = try makeModel(pages: [.success(try livePage(ids: 1 ... 1))])
        await model.loadInitial()
        model.scrollRequestDidFinish(id: model.updates.value.pendingScroll!.id)
        model.userScrollBegan()
        model.viewportDidChange(.init(firstVisibleIndex: 0, lastVisibleIndex: 0, distanceToTop: 0, distanceToBottom: 500, height: 400), reason: .user, revision: model.updates.value.revision)
        XCTAssertFalse(model.state.live.isPinnedToBottom)

        model.receiveLive(try TimelineTestFixtures.message(id: "2", senderID: 2, at: 2))

        XCTAssertEqual(model.state.live.unseenCount, 1)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1", "2"])
        XCTAssertNil(updates.value.last?.pendingScroll)
        XCTAssertEqual(source.store.bufferedLiveEventCountForTesting(chatID: "chat"), 0, "a row rendered from the window must not linger in the deferred buffer")
    }

    func testPinnedViewportAtLiveEdgeClearsUnseenCount() async throws {
        let (model, _, _) = try makeModel(pages: [.success(try livePage(ids: 1 ... 1))])
        await model.loadInitial()
        model.scrollRequestDidFinish(id: model.updates.value.pendingScroll!.id)
        model.userScrollBegan()
        model.viewportDidChange(.init(firstVisibleIndex: 0, lastVisibleIndex: 0, distanceToTop: 0, distanceToBottom: 500, height: 400), reason: .user, revision: model.updates.value.revision)
        model.receiveLive(try TimelineTestFixtures.message(id: "2", senderID: 2, at: 2))
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
        model.receiveLive(try TimelineTestFixtures.message(id: "100", senderID: 2, at: 40, minute: 1))
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
        XCTAssertEqual(source.store.bufferedLiveEventCountForTesting(chatID: "chat"), 0)
    }

    func testJumpToLiveEdgeDropsDeferredArrivalOlderThanNewWindow() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1 ... 2, newerCursor: "2")),
            .success(try livePage(ids: 98 ... 99)),
        ])
        await model.loadInitial()
        // Predates 98 @ 01:38: replaying it would render above a history gap.
        model.receiveLive(try TimelineTestFixtures.message(id: "3", senderID: 2, at: 3))

        await model.jumpToLiveEdge()

        XCTAssertEqual(model.rows.compactMap(\.messageID), ["98", "99"], "stale deferred entry must not be injected above the gap")
        XCTAssertEqual(source.store.bufferedLiveEventCountForTesting(chatID: "chat"), 0, "stale entry is discarded, not left in the buffer")
    }

    func testInitialLoadPrunesStaleDeferredArrivalLeftByAPriorOpen() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 98 ... 99))])
        // A previous screen for this chat buffered these while off-edge; the store outlives it.
        source.store.receiveLive(try TimelineTestFixtures.message(id: "3", senderID: 2, at: 3))            // predates 98 → drop
        source.store.receiveLive(try TimelineTestFixtures.message(id: "100", senderID: 2, at: 40, minute: 1)) // newer than 99 → replay

        await model.loadInitial()

        XCTAssertEqual(model.rows.compactMap(\.messageID), ["98", "99", "100"])
        XCTAssertEqual(source.store.bufferedLiveEventCountForTesting(chatID: "chat"), 0)
    }

    func testInstallReconcilesDeferredBufferByIdentityNotTimestamp() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 98 ... 99))])
        // Same ID as the page's newest row with an identical createdAt: a date-only compare would
        // keep it and leave the buffer dirty; identity must drop it (server copy wins).
        source.store.receiveLive(try TimelineTestFixtures.message(id: "99", senderID: 2, at: 39, minute: 1))
        // Ties the newest row's createdAt but is a different message the page did not include.
        // Nothing newer exists to page toward, so it must be replayed, not dropped.
        source.store.receiveLive(try TimelineTestFixtures.message(id: "99b", senderID: 2, at: 39, minute: 1))

        await model.loadInitial()

        XCTAssertEqual(model.rows.compactMap(\.messageID), ["98", "99", "99b"])
        XCTAssertEqual(source.store.bufferedLiveEventCountForTesting(chatID: "chat"), 0)
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
    private var inFlight: [Task<Void, Never>] = []

    init(pages: [Result<ListMessagesResponse, Error>]) {
        self.pages = pages
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        queries.append(query)
        precondition(!pages.isEmpty, "Unscripted fetch: \(query)")
        await Task.yield()
        return try pages.removeFirst().get()
    }

    /// Lets detached edge-load tasks run to completion.
    func drain() async {
        for _ in 0 ..< 8 { await Task.yield() }
    }
}
