#if os(macOS)
import AppKit
import ChahuaAPI
import SwiftUI
import XCTest
@testable import chahua_apple

@MainActor
final class MessageRowLayoutTests: XCTestCase {
    func testReactionsStayBelowBubbleAndAvatarOnBothSides() async throws {
        for outgoing in [false, true] {
            let message = try TimelineTestFixtures.message(id: "accessories", senderID: outgoing ? 1 : 2, at: 0, fields: [
                "message": "Body with a final line\nFinal visible line",
                "threadInfo": ["replyCount": 7],
                "reactions": [
                    ["emoji": "\u{1F44D}", "count": 8, "reactors": (1 ... 5).map { ["uid": $0] }],
                    ["emoji": "\u{2764}", "count": 3], ["emoji": "\u{1F389}", "count": 2]
                ]
            ])
            let row = TimelineRow.message(.init(entry: .remote(message), isOutgoing: outgoing, groupPosition: .single, showsSenderName: true))
            for width: CGFloat in [320, 600] {
                let environment = TimelineLayoutEnvironment.current(timelineWidth: width, bodySize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                    captionSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, caption2Size: NSFont.preferredFont(forTextStyle: .caption2).pointSize)
                let presentation = TimelineRowPresentation.make(row: row, currentUserProfile: nil, currentUserID: 1, isThreadTimeline: false, environment: environment)
                let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
                let bubble = try XCTUnwrap(layout.frames[.bubble])
                let avatar = try XCTUnwrap(layout.frames[.avatar])
                let reactions = try XCTUnwrap(layout.frames[.reactions])
                let thread = try XCTUnwrap(layout.frames[.thread])
                XCTAssertEqual(avatar.maxY, bubble.maxY, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(reactions.minY, max(avatar.maxY, bubble.maxY) + 8)
                XCTAssertTrue(bubble.contains(thread))
                XCTAssertEqual(thread.minX, bubble.minX, accuracy: 0.5)
                XCTAssertEqual(thread.maxX, bubble.maxX, accuracy: 0.5)
                XCTAssertEqual(thread.maxY, bubble.maxY, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(thread.minY, try XCTUnwrap(layout.frames[.text]).maxY)
                XCTAssertGreaterThanOrEqual(layout.size.height - reactions.maxY, 8)
                XCTAssertLessThanOrEqual(bubble.width, environment.centralWidth)
                let host = NSViewController()
                let nativeRow = TimelineRowView()
                nativeRow.bind(.init(presentation: presentation, layout: layout, context: .init(currentUserID: 1), actions: .init(), mediaContext: nil))
                host.view = nativeRow
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: layout.size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentViewController = host
                window.setContentSize(layout.size)
                host.view.frame = CGRect(origin: .zero, size: layout.size)
                window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(50))
                host.view.layoutSubtreeIfNeeded()
                let text = try XCTUnwrap(textView(in: host.view))
                let rendered = text.convert(text.bounds, to: host.view)
                XCTAssertTrue(host.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rendered))
                XCTAssertEqual(rendered.width, try XCTUnwrap(layout.frames[.text]).width, accuracy: 0.5)
                XCTAssertEqual(rendered.height, try XCTUnwrap(layout.frames[.text]).height, accuracy: 0.5)
                let glyphs = text.contentLayout.layoutManager.usedRect(for: text.contentLayout.textContainer)
                    .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
                XCTAssertTrue(text.bounds.insetBy(dx: -0.5, dy: -0.5).contains(glyphs), "The last caption glyph must fit its native text frame.")
            }
        }
    }


    func testThreadFooterReservesTheCompleteLabelAndDisappearsInThreadTimeline() throws {
        let message = try TimelineTestFixtures.message(id: "thread-footer", senderID: 2, at: 0,
            fields: ["message": "Hi", "threadInfo": ["replyCount": 14]])
        for outgoing in [false, true] {
            let row = TimelineRow.message(.init(entry: .remote(message), isOutgoing: outgoing,
                groupPosition: .single, showsSenderName: false))
            for fontSize: CGFloat in [13, 26] {
                let environment = TimelineLayoutEnvironment.current(timelineWidth: 600, bodySize: fontSize)
                let presentation = TimelineRowPresentation.make(row: row, currentUserProfile: nil,
                    currentUserID: 1, isThreadTimeline: false, environment: environment)
                let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
                let footer = try XCTUnwrap(layout.frames[.thread])
                let items = layout.threadContentFrames
                XCTAssertEqual(items.count, 3)
                let label = try XCTUnwrap(presentation.threadLabel)
                let measured = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: fontSize)]).size()
                XCTAssertGreaterThanOrEqual(items[1].width + 0.5, measured.width)
                XCTAssertGreaterThanOrEqual(items[1].height + 0.5, measured.height)
                for item in items {
                    XCTAssertTrue(CGRect(origin: .zero, size: footer.size).insetBy(dx: -0.5, dy: -0.5).contains(item))
                }
                XCTAssertLessThanOrEqual(items[0].maxX, items[1].minX)
                XCTAssertLessThanOrEqual(items[1].maxX, items[2].minX)

                let threadPresentation = TimelineRowPresentation.make(row: row, currentUserProfile: nil,
                    currentUserID: 1, isThreadTimeline: true, environment: environment)
                let threadLayout = TimelineLayoutEngine().layout(threadPresentation, environment: environment)
                XCTAssertNil(threadLayout.frames[.thread])
            }
        }
    }

    func testThreadFooterUsesCurrentMessageAndIsReadOnlyInPreview() throws {
        var opened: [String] = []
        func binding(id: String, preview: Bool = false, hasThread: Bool = true) throws -> TimelineRowBinding {
            var fields: [String: Any] = ["message": "Thread root"]
            if hasThread { fields["threadInfo"] = ["replyCount": 14] }
            let message = try TimelineTestFixtures.message(id: id, senderID: 2, at: 0, fields: fields)
            let row = TimelineRow.message(.init(entry: .remote(message), isOutgoing: false, groupPosition: .single, showsSenderName: false))
            let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
            let presentation = TimelineRowPresentation.make(row: row, currentUserProfile: nil,
                currentUserID: 1, isThreadTimeline: false, environment: environment)
            var actions = TimelineBubbleActions()
            actions.openThread = { opened.append($0) }
            return .init(presentation: presentation, layout: TimelineLayoutEngine().layout(presentation, environment: environment),
                context: .init(currentUserID: 1, isInteractionPreview: preview), actions: actions, mediaContext: nil)
        }
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let first = try binding(id: "first")
        let native = TimelineBubbleContentView(frame: CGRect(origin: .zero, size: try XCTUnwrap(first.layout.frames[.bubble]).size))
        native.bind(first)
        native.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(buttons(in: native).first { $0.accessibilityLabel() == first.presentation.threadLabel })
        button.performClick(nil)
        native.bind(try binding(id: "second"))
        button.performClick(nil)
        XCTAssertEqual(opened, ["first", "second"])
        native.bind(try binding(id: "preview", preview: true))
        XCTAssertFalse(button.isHidden)
        button.performClick(nil)
        native.bind(try binding(id: "no-thread", hasThread: false))
        button.performClick(nil)
        XCTAssertEqual(opened, ["first", "second"])
    }

    func testReusedRowPreservesSameMessageSelectionButResetsForAnotherMessage() async throws {
        var opened: [String] = []
        func binding(id: String, width: CGFloat) throws -> TimelineRowBinding {
            let message = try TimelineTestFixtures.message(id: id, senderID: 2, at: 0, text: "Hello https://example.com")
            let row = TimelineRow.message(.init(entry: .remote(message), isOutgoing: false, groupPosition: .single, showsSenderName: true))
            let environment = TimelineLayoutEnvironment.current(timelineWidth: width)
            let presentation = TimelineRowPresentation.make(row: row, currentUserProfile: nil, currentUserID: 1, isThreadTimeline: false, environment: environment)
            var actions = TimelineBubbleActions()
            actions.openLink = { _ in opened.append(id) }
            return .init(presentation: presentation, layout: TimelineLayoutEngine().layout(presentation, environment: environment),
                         context: .init(currentUserID: 1), actions: actions, mediaContext: nil)
        }
        let first = try binding(id: "first", width: 600)
        let cell = TimelineTableCellView(frame: CGRect(origin: .zero, size: first.layout.size))
        let window = NSWindow(contentRect: cell.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = cell
        window.orderFront(nil)
        defer { window.close() }
        cell.bind(first)
        try await Task.sleep(for: .milliseconds(50))
        cell.layoutSubtreeIfNeeded()
        let initialText = try XCTUnwrap(textView(in: cell))
        initialText.setSelectedRange(NSRange(location: 0, length: 5))

        let resized = try binding(id: "first", width: 400)
        window.setContentSize(resized.layout.size)
        cell.bind(resized)
        try await Task.sleep(for: .milliseconds(50))
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(textView(in: cell)).selectedRange(), NSRange(location: 0, length: 5))

        cell.bind(try binding(id: "second", width: 400))
        try await Task.sleep(for: .milliseconds(50))
        cell.layoutSubtreeIfNeeded()
        let reusedText = try XCTUnwrap(textView(in: cell))
        XCTAssertEqual(reusedText.string, "Hello https://example.com")
        XCTAssertEqual(reusedText.selectedRange().length, 0, "Selection must not transfer to another message with identical text.")
        _ = reusedText.delegate?.textView?(reusedText, clickedOnLink: URL(string: "https://example.com")!, at: 6)
        XCTAssertEqual(opened, ["second"], "Reused content must dispatch the current message's action.")
    }

    func testReusingReplyableRowForDeletedSystemMessageRemovesHoverAction() throws {
        let nativeRow = TimelineRowView()
        let window = HoverPointerWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 150),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = nativeRow
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var replies: [String] = []
        var actions = TimelineBubbleActions()
        actions.replyToMessage = { replies.append($0.id) }
        actions.interactionContext = .init(canWrite: true)
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        for system in [false, true] {
            let message = try TimelineTestFixtures.message(id: system ? "system" : "text", at: 0,
                fields: ["messageType": system ? "system" : "text", "isDeleted": system])
            let row = TimelineRow.message(.init(entry: .remote(message), isOutgoing: false,
                                               groupPosition: .single, showsSenderName: true))
            let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
            let presentation = TimelineRowPresentation.make(row: row, currentUserProfile: nil,
                currentUserID: 1, isThreadTimeline: false, environment: environment)
            nativeRow.bind(.init(presentation: presentation,
                layout: TimelineLayoutEngine().layout(presentation, environment: environment),
                context: .init(currentUserID: 1), actions: actions, mediaContext: nil))
            nativeRow.setVisible(true)
            nativeRow.mouseEntered(with: entered)
            nativeRow.layoutSubtreeIfNeeded()
            let buttons = nativeRow.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            if system {
                XCTAssertTrue(buttons.isEmpty, "System rows must not expose a zero-sized reply action after reuse.")
            } else {
                try XCTUnwrap(buttons.first).performClick(nil)
                XCTAssertEqual(replies, ["text"])
            }
        }
    }

    func testScrollingUnderStationaryPointerTransfersReplyHoverWithoutExitEvent() throws {
        let window = HoverPointerWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 200),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = document
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var actions = TimelineBubbleActions()
        actions.replyToMessage = { _ in }
        actions.interactionContext = .init(canWrite: true)
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
        let rows = try (0 ..< 2).map { index -> TimelineRowView in
            let message = try TimelineTestFixtures.message(id: "hover-\(index)", at: index)
            let row = TimelineRow.message(.init(entry: .remote(message), isOutgoing: false,
                                               groupPosition: .single, showsSenderName: true))
            let presentation = TimelineRowPresentation.make(row: row, currentUserProfile: nil,
                currentUserID: 1, isThreadTimeline: false, environment: environment)
            let view = TimelineRowView(frame: CGRect(x: 0, y: index * 100, width: 600, height: 100))
            document.addSubview(view)
            view.bind(.init(presentation: presentation,
                layout: TimelineLayoutEngine().layout(presentation, environment: environment),
                context: .init(), actions: actions, mediaContext: nil))
            return view
        }
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: window.pointer, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        func showsReply(_ row: TimelineRowView) -> Bool {
            row.subviews.contains { $0 is NSButton && !$0.isHidden }
        }
        scroll.contentView.scroll(to: .zero)
        rows.forEach { $0.setVisible(true) }
        rows[0].mouseEntered(with: entered)
        XCTAssertEqual(rows.map(showsReply), [true, false])

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
        // Both rows remain visible; neither reuse nor a mouseExited event clears
        // the old row. This is the viewport refresh used by the native table.
        XCTAssertTrue(rows.allSatisfy { !$0.visibleRect.isEmpty })
        rows.forEach { $0.setVisible(true) }
        XCTAssertEqual(rows.map(showsReply), [false, true])
        rows[0].mouseEntered(with: entered)
        XCTAssertEqual(rows.map(showsReply), [false, true], "A delayed enter event must not resurrect the old row's hover.")

        scroll.contentView.scroll(to: .zero)
        rows.forEach { $0.setVisible(true) }
        XCTAssertEqual(rows.map(showsReply), [true, false])
        window.active = false
        rows.forEach { $0.setVisible(true) }
        XCTAssertEqual(rows.map(showsReply), [false, false])
    }

    private func textView(in view: NSView) -> AppKitMessageTextView? {
        if let text = view as? AppKitMessageTextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }
}
private final class HoverPointerWindow: NSWindow {
    let pointer = NSPoint(x: 50, y: 50)
    var active = true
    override var isKeyWindow: Bool { active }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

#endif
