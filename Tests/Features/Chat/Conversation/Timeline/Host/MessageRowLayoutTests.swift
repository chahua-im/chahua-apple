#if os(macOS)
import AppKit
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
                XCTAssertGreaterThanOrEqual(thread.minY, reactions.maxY + 4)
                XCTAssertGreaterThanOrEqual(layout.size.height - thread.maxY, 8)
                XCTAssertLessThanOrEqual(bubble.width, environment.centralWidth)
                let host = NSHostingController(rootView: TimelineBubbleView(presentation: presentation, layout: layout, context: .init(currentUserID: 1)))
                host.sizingOptions = []
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

    private func textView(in view: NSView) -> AppKitMessageTextView? {
        if let text = view as? AppKitMessageTextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }
}
#endif
