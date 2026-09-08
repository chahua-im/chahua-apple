#if os(macOS)
import AppKit
import Combine
import SwiftUI
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

    func testShortMessagesStayCompactAndGlyphsRemainInsideTheirRows() async throws {
        for sender: Int32 in [1, 2] {
            for text in ["Hello", "Hi\nBye"] {
                try await inspectRenderedMessage(text: text, senderID: sender, widths: [320, 600, 900]) { cell, textView, bitmap in
                    self.assertGlyphsVisible(textView, in: cell)
                    let bubbleWidth = self.backgroundWidth(in: bitmap, outgoing: sender == 1)
                    XCTAssertGreaterThan(bubbleWidth, 30, "The rendered bubble background must be present.")
                    XCTAssertLessThan(bubbleWidth, 180, "Short lines must not fill the maximum conversation lane.")
                }
            }
        }
    }

    func testWrappedMessageGlyphsFitAfterNarrowingAndWideningTheTimeline() async throws {
        let text = "First line\n你好，世界 👨‍👩‍👧‍👦\n" + String(repeating: "Wrapping text remains visible. ", count: 4)
            + "\n" + String(repeating: "x", count: 160) + "\nFinal line"
        try await inspectRenderedMessage(text: text, senderID: 2, widths: [900, 320, 600]) { cell, textView, _ in
            self.assertGlyphsVisible(textView, in: cell)
            XCTAssertEqual(textView.string, text)
        }
    }

    func testReplyGalleryCaptionAndThreadStayInsideTheResizedMessage() async throws {
        let caption = "Caption after gallery\nFinal visible caption line"
        try await inspectRenderedMessage(
            text: caption, senderID: 2, widths: [900, 320, 600],
            enrich: { object in
                object["isEdited"] = true
                object["threadInfo"] = ["replyCount": 7]
                object["replyToMessage"] = [
                    "id": "quoted-target", "clientGeneratedId": "quoted-client",
                    "createdAt": object["createdAt"]!, "sender": object["sender"]!,
                    "messageType": "text", "message": "A long quoted message " + String(repeating: "that must truncate ", count: 10),
                    "attachments": [], "mentions": [], "isDeleted": false
                ]
                object["hasAttachments"] = true
                object["attachments"] = (0 ..< 7).map { index in
                    ["id": "image-\(index)", "url": "file:///chahua-test-missing-\(index).png", "kind": "image/png",
                     "size": 1, "fileName": "image.png", "width": 200 + index * 100, "height": 300] as [String: Any]
                }
            }
        ) { cell, textView, bitmap in
            self.assertGlyphsVisible(textView, in: cell)
            XCTAssertLessThanOrEqual(self.backgroundWidth(in: bitmap, outgoing: false), (cell.bounds.width - 68) * 0.75 + 1)
        }
    }

    func testIncomingMetadataRemainsReadableInDarkAppearance() async throws {
        try await inspectRenderedMessage(text: "Hello", senderID: 2, widths: [320], appearance: .darkAqua) { cell, textView, bitmap in
            guard let native = textView as? MacBubbleTextView else { return XCTFail("Missing native text view") }
            let frame = cell.convert(native.contentLayout.geometry(for: native.bounds.width).metadataFrame, from: native)
            let scaleX = CGFloat(bitmap.pixelsWide) / cell.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / cell.bounds.height
            let top = cell.isFlipped ? frame.minY : cell.bounds.height - frame.maxY
            var brightest: CGFloat = 0
            for y in max(0, Int(top * scaleY)) ..< min(bitmap.pixelsHigh, Int(ceil((top + frame.height) * scaleY))) {
                for x in max(0, Int(frame.minX * scaleX)) ..< min(bitmap.pixelsWide, Int(ceil(frame.maxX * scaleX))) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                    brightest = max(brightest, color.redComponent, color.greenComponent, color.blueComponent)
                }
            }
            XCTAssertGreaterThan(brightest, 0.4, "Timestamp ink must be visible against the dark incoming bubble.")
        }
    }

    private func inspectRenderedMessage(
        text: String, senderID: Int32, widths: [CGFloat],
        appearance: NSAppearance.Name = .aqua,
        enrich: ((inout [String: Any]) -> Void)? = nil,
        check: (NSView, NSTextView, NSBitmapImageRep) -> Void
    ) async throws {
        let base = try TimelineTestFixtures.message(id: "visible-text", senderID: senderID, at: 0, text: "Fixture")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(base)) as? [String: Any])
        object["message"] = text
        enrich?(&object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(MessageResponse.self, from: JSONSerialization.data(withJSONObject: object))
        let page = try TimelineTestFixtures.page([message])
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: HistorySource(initial: page, older: page), messageStore: ConversationMessageStore()
        )
        let controller = TimelineTableViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: widths[0], height: 1100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        await model.loadInitial()
        window.appearance = NSAppearance(named: appearance)
        for width in widths {
            window.setContentSize(NSSize(width: width, height: 1100))
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()
            controller.view.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
            let table = try XCTUnwrap(scroll.documentView as? NSTableView)
            let index = try XCTUnwrap(model.rows.firstIndex { $0.messageID == "visible-text" })
            table.scrollRowToVisible(index)
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: index, makeIfNecessary: true))
            cell.layoutSubtreeIfNeeded()
            let textView = try XCTUnwrap(textViews(in: cell).first { $0.string == text })
            let bitmap = try XCTUnwrap(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
            cell.cacheDisplay(in: cell.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "native-bubble-\(senderID)-\(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            check(cell, textView, bitmap)
        }
    }

    private func assertGlyphsVisible(_ textView: NSTextView, in cell: NSView, file: StaticString = #filePath, line: UInt = #line) {
        guard let manager = textView.layoutManager, let container = textView.textContainer else {
            return XCTFail("Selectable text must have a laid-out text container.", file: file, line: line)
        }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(for: container)
        XCTAssertEqual(NSMaxRange(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)),
                       (textView.string as NSString).length, "Every character must be laid out.", file: file, line: line)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
        var ancestor: NSView? = textView
        while let view = ancestor {
            if view === textView || view === cell || view is NSHostingView<TimelineBubbleView> || view.clipsToBounds {
                let converted = view.convert(rect, from: textView)
                XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(converted),
                              "Glyphs \(converted) are clipped by \(type(of: view)) bounds \(view.bounds).", file: file, line: line)
            }
            if view === cell { break }
            ancestor = view.superview
        }
    }

    private func backgroundWidth(in bitmap: NSBitmapImageRep, outgoing: Bool) -> CGFloat {
        var longest = 0
        for y in 0 ..< bitmap.pixelsHigh {
            var run = 0
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let matches = outgoing
                    ? color.blueComponent > color.redComponent + 0.2 && color.greenComponent > 0.3 && color.greenComponent < 0.7
                    : abs(color.redComponent - color.greenComponent) < 0.02 && abs(color.greenComponent - color.blueComponent) < 0.02 && color.redComponent > 0.8 && color.redComponent < 0.97
                run = matches ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return CGFloat(longest) * bitmap.size.width / CGFloat(bitmap.pixelsWide)
    }


    func testLiveResizeSettlesEveryRowAtFinalWidth() async throws {
        let page = try TimelineTestFixtures.page((0 ..< 40).map {
            try TimelineTestFixtures.message(id: "\($0)", senderID: 2, at: $0,
                text: String(repeating: "Wrapping text during interactive resizing. ", count: 4))
        })
        let model = ConversationTimelineModel(chatID: "chat", currentUserID: 1, isGroupChat: true,
            source: HistorySource(initial: page, older: page), messageStore: ConversationMessageStore())
        let controller = TimelineTableViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        await model.loadInitial()
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        for width: CGFloat in [600, 900, 320] {
            window.setContentSize(NSSize(width: width, height: 600))
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()
            let visible = table.rows(in: scroll.documentVisibleRect)
            for index in visible.location ..< min(NSMaxRange(visible), model.rows.count) {
                guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) else { continue }
                cell.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
                cell.cacheDisplay(in: cell.bounds, to: bitmap)
                for text in textViews(in: cell) { assertGlyphsVisible(text, in: cell) }
            }
        }
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        XCTAssertEqual(table.bounds.height - scroll.documentVisibleRect.maxY, 0, accuracy: 1)

        let referenceModel = ConversationTimelineModel(chatID: "chat", currentUserID: 1, isGroupChat: true,
            source: HistorySource(initial: page, older: page), messageStore: ConversationMessageStore())
        let reference = TimelineTableViewController(model: referenceModel)
        reference.view.frame = controller.view.frame
        reference.view.layoutSubtreeIfNeeded()
        reference.viewDidLayout()
        await referenceModel.loadInitial()
        let referenceScroll = try XCTUnwrap(reference.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let referenceTable = try XCTUnwrap(referenceScroll.documentView as? NSTableView)
        for index in model.rows.indices {
            XCTAssertEqual(table.rect(ofRow: index).height, referenceTable.rect(ofRow: index).height, accuracy: 1,
                           "Offscreen rows must settle to the same geometry as a fresh timeline at the final width.")
        }
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

private func textViews(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? [] + view.subviews.flatMap(textViews)
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
