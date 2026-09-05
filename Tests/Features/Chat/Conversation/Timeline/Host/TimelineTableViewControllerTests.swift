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
#endif
