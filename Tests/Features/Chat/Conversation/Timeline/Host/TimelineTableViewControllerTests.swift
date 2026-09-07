#if os(macOS)
import AppKit
import Combine
import XCTest
import ChahuaAPI
@testable import chahua_apple

@MainActor
final class TimelineTableViewControllerTests: XCTestCase {
    func testUserScrollLoadsHistoryButLayoutDoesNot() async throws {
        try await checkHistoryScroll(legacyMouse: false)
    }

    func testLegacyMouseWheelLoadsHistoryWithoutJumpingToBottom() async throws {
        try await checkHistoryScroll(legacyMouse: true)
    }

    func testSameDayPrependPreservesVisibleMessagesAtDateSeparator() async throws {
        try await checkSameDayPrepend(scrollY: 0)
    }

    func testSameDayPrependPreservesVisibleMessagesAtMessageRow() async throws {
        try await checkSameDayPrepend(scrollY: 100)
    }

    func testLiveArrivalDuringInitialScrollCompletionIsRenderedWithoutAnotherLayout() async throws {
        let page = try TimelineTestFixtures.page([TimelineTestFixtures.message(id: "0", at: 0)])
        let live = try TimelineTestFixtures.message(id: "1", at: 1)
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: HistorySource(initial: page, older: page), messageStore: ConversationMessageStore()
        )
        let controller = TimelineTableViewController(model: model)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        var delivered = false
        let subscription = model.updates.sink { snapshot in
            guard !delivered, snapshot.pendingScroll == nil, !snapshot.rows.isEmpty else { return }
            delivered = true
            model.receiveLive(live)
        }
        defer { subscription.cancel() }

        await model.loadInitial()
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["0", "1"])
        XCTAssertEqual(table.numberOfRows, model.rows.count,
                       "A reentrant live update must not wait for an unrelated future layout")
        XCTAssertNil(model.updates.value.pendingScroll)
    }

    func testResizingPreservesBottomAttachmentAndHistoryAnchor() async throws {
        let page = try TimelineTestFixtures.page((0 ..< 40).map {
            try TimelineTestFixtures.message(
                id: "\($0)", senderID: 2, at: $0,
                text: String(repeating: "Wrapping text changes the height of this message. ", count: 4)
            )
        })
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true,
            source: HistorySource(initial: page, older: page), messageStore: ConversationMessageStore()
        )
        let controller = TimelineTableViewController(model: model)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        await model.loadInitial()
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)

        controller.view.setFrameSize(NSSize(width: 600, height: 300))
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        XCTAssertEqual(table.bounds.height - scroll.documentVisibleRect.maxY, 0, accuracy: 1,
                       "A height-only resize must keep the latest message attached to the bottom")

        model.userScrollBegan()
        let index = try XCTUnwrap(model.rows.firstIndex { $0.messageID == "10" })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: index).minY + 12))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        let offset = table.rect(ofRow: index).minY - scroll.documentVisibleRect.minY

        controller.view.setFrameSize(NSSize(width: 320, height: 400))
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        XCTAssertEqual(table.rect(ofRow: index).minY - scroll.documentVisibleRect.minY, offset, accuracy: 1,
                       "Reflow must preserve the partially visible message, not the old absolute offset")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(table.rect(ofRow: index).minY - scroll.documentVisibleRect.minY, offset, accuracy: 1,
                       "A delayed row-height animation must not move the reader after restoration")
        XCTAssertFalse(model.state.live.followsLatest)
    }

    func testUserScrollCancelsAnimatedJumpWithoutLaterMovement() async throws {
        let page = try TimelineTestFixtures.page((0 ..< 25).map {
            try TimelineTestFixtures.message(id: "\($0)", at: $0)
        })
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: HistorySource(initial: page, older: page), messageStore: ConversationMessageStore()
        )
        let controller = TimelineTableViewController(model: model)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        await model.loadInitial()
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        model.userScrollBegan()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        await model.jumpToLiveEdge()
        XCTAssertNotNil(model.updates.value.pendingScroll)
        try await Task.sleep(for: .milliseconds(50))

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        XCTAssertNil(model.updates.value.pendingScroll)
        let userPosition = scroll.documentVisibleRect.minY
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(scroll.documentVisibleRect.minY, userPosition, accuracy: 1,
                       "Cancelled navigation must not overwrite the user's new position")
        XCTAssertFalse(model.state.live.followsLatest)
    }

    private func checkSameDayPrepend(scrollY: CGFloat) async throws {
        func page(_ ids: ClosedRange<Int>, olderCursor: String?) throws -> ListMessagesResponse {
            try TimelineTestFixtures.page(ids.map {
                try TimelineTestFixtures.message(id: "\($0)", at: $0 % 60, hour: 12, minute: $0 / 60)
            }, olderCursor: olderCursor)
        }
        let source = PagedHistorySource(pages: [
            try page(60 ... 109, olderCursor: "60"),
            try page(10 ... 59, olderCursor: "10"),
            try page(0 ... 9, olderCursor: nil),
        ])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: source, messageStore: ConversationMessageStore(), calendar: calendar
        )
        let controller = TimelineTableViewController(model: model)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        await model.loadInitial()
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        let scrollView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let visible = scrollView.documentVisibleRect
        let range = tableView.rows(in: visible)
        let messageIndex = try XCTUnwrap(model.rows.indices.first {
            NSLocationInRange($0, range) && model.rows[$0].messageID != nil
        })
        let messageID = model.rows[messageIndex].id
        let offsetBefore = tableView.rect(ofRow: messageIndex).minY - visible.minY
        if scrollY == 0 {
            guard case .dateSeparator = model.rows[range.location] else {
                return XCTFail("Reproduction requires a visible leading date separator")
            }
        } else {
            XCTAssertNotNil(model.rows[range.location].messageID)
        }

        let loaded = expectation(description: "first older page installed")
        let subscription = model.updates
            .filter { $0.rows.contains { $0.messageID == "10" } }
            .first()
            .sink { _ in loaded.fulfill() }
        defer { subscription.cancel() }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        await fulfillment(of: [loaded], timeout: 2)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        XCTAssertEqual(source.queries.compactMap(\.before), ["60"])
        let newIndex = try XCTUnwrap(model.rows.firstIndex { $0.id == messageID })
        let offsetAfter = tableView.rect(ofRow: newIndex).minY - scrollView.documentVisibleRect.minY
        XCTAssertEqual(offsetAfter, offsetBefore, accuracy: 0.5,
                       "Prepending within a day must preserve the visible message, not just its date separator")

        // A subsequent live-scroll callback without further movement models a wheel gesture
        // still arriving at the top. The inserted full page should have moved us out of prefetch.
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        XCTAssertEqual(model.state.older, .idle, "Layout alone must not start another page")
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        if model.state.older == .loading {
            let nextLoaded = expectation(description: "unexpected second older page installed")
            let nextSubscription = model.updates
                .filter { $0.rows.contains { $0.messageID == "0" } }
                .first()
                .sink { _ in nextLoaded.fulfill() }
            defer { nextSubscription.cancel() }
            await fulfillment(of: [nextLoaded], timeout: 2)
        }
        XCTAssertEqual(source.queries.compactMap(\.before), ["60"],
                       "Without further upward movement, restoring the reader should prevent another page request")
    }

    func testTimelineHasNoHorizontalScrollRangeAfterResizing() async throws {
        let page = try TimelineTestFixtures.page((10 ... 59).map {
            try TimelineTestFixtures.message(id: "\($0)", at: $0)
        })
        let source = HistorySource(initial: page, older: page)
        let model = ConversationTimelineModel(chatID: "chat", currentUserID: 1, isGroupChat: false, source: source, messageStore: ConversationMessageStore())
        let controller = TimelineTableViewController(model: model)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        await model.loadInitial()
        let scrollView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)

        for width: CGFloat in [800, 400, 900, 300] {
            controller.view.setFrameSize(NSSize(width: width, height: 400))
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()
            controller.view.layoutSubtreeIfNeeded()
            let clip = scrollView.contentView
            XCTAssertEqual(tableView.frame.width, clip.bounds.width, accuracy: 0.5)
            var proposed = clip.bounds
            proposed.origin.x = 100
            XCTAssertEqual(clip.constrainBoundsRect(proposed).origin.x, 0, accuracy: 0.5)
            proposed.origin.x = -100
            XCTAssertEqual(clip.constrainBoundsRect(proposed).origin.x, 0, accuracy: 0.5)
            XCTAssertGreaterThan(tableView.frame.height, clip.bounds.height, "vertical history scrolling remains available")
        }
    }

    private func checkHistoryScroll(legacyMouse: Bool) async throws {
        let messages = try (10 ... 59).map {
            try TimelineTestFixtures.message(id: "\($0)", at: $0)
        }
        let older = try TimelineTestFixtures.message(id: "9", at: 9)
        let source = HistorySource(
            initial: try TimelineTestFixtures.page(messages, olderCursor: "10"),
            older: try TimelineTestFixtures.page([older])
        )
        let model = ConversationTimelineModel(chatID: "chat", currentUserID: 1, isGroupChat: false, source: source, messageStore: ConversationMessageStore())
        let controller = TimelineTableViewController(model: model)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        await model.loadInitial()
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        let scrollView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        XCTAssertGreaterThan(tableView.bounds.height, scrollView.contentView.bounds.height)

        // A programmatic move/layout near the top must not fetch history.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        XCTAssertEqual(model.state.older, .idle)
        XCTAssertEqual(source.queries.count, 1)

        let loaded = expectation(description: "older message is rendered")
        let subscription = model.updates.sink { snapshot in
            if snapshot.rows.contains(where: { $0.messageID == "9" }) { loaded.fulfill() }
        }
        defer { subscription.cancel() }
        // AppKit documents that legacy wheels send didLiveScroll without willStart.
        if !legacyMouse {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            XCTAssertFalse(model.state.live.followsLatest)
        }
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        XCTAssertEqual(model.state.older, .loading)
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(source.queries.count, 2)
        XCTAssertEqual(source.queries.last?.before, "10")
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["9"] + messages.map(\.id))
        XCTAssertFalse(model.state.live.followsLatest)
        XCTAssertGreaterThan(scrollView.documentVisibleRect.minY, 0, "prepending history preserves the reader's position")
        XCTAssertGreaterThan(tableView.bounds.height - scrollView.documentVisibleRect.maxY, 400, "history loading must not jump to the bottom")
    }
}

@MainActor
private final class HistorySource: TimelineMessageSource {
    let initial: ListMessagesResponse
    let older: ListMessagesResponse
    var queries: [ListMessagesQuery] = []

    init(initial: ListMessagesResponse, older: ListMessagesResponse) {
        self.initial = initial
        self.older = older
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        queries.append(query)
        return query.before == nil ? initial : older
    }
}

@MainActor
private final class PagedHistorySource: TimelineMessageSource {
    private var pages: [ListMessagesResponse]
    private(set) var queries: [ListMessagesQuery] = []

    init(pages: [ListMessagesResponse]) { self.pages = pages }

    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        queries.append(query)
        guard !pages.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return pages.removeFirst()
    }
}
#endif
