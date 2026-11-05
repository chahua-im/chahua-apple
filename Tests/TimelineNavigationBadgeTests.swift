#if os(macOS)
    import AppKit
    import XCTest
    @testable import chahua_apple

    @MainActor
    final class TimelineNavigationBadgeTests: XCTestCase {
        func testUnreadLabelsStayCenteredForCircularAndWideBadges() throws {
            let controls = TimelineNativeNavigationControls(
                frame: NSRect(x: 20, y: 20, width: 40, height: 40))
            let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
            canvas.addSubview(controls)
            let window = NSWindow(
                contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = canvas
            defer { window.close() }
            func label(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField { return field }
                for child in view.subviews { if let result = label(in: child) { return result } }
                return nil
            }
            for count: Int64 in [1, 12, 999, 1000] {
                controls.configure(
                    showsLatest: true, messages: count, mentions: 0, reactions: 0,
                    busy: false, badgeColor: ConversationListPreferences.defaultUnreadBadgeColor)
                canvas.layoutSubtreeIfNeeded()
                let button = try XCTUnwrap(controls.subviews.first { !$0.isHidden } as? NSButton)
                let text = try XCTUnwrap(label(in: button))
                let background = try XCTUnwrap(text.superview)
                XCTAssertEqual(text.stringValue, count > 999 ? "999+" : String(count))
                XCTAssertEqual(text.frame.midX, background.bounds.midX, accuracy: 0.5)
                XCTAssertEqual(text.frame.midY, background.bounds.midY, accuracy: 0.5)
                XCTAssertLessThan(text.frame.height, background.bounds.height)
                XCTAssertGreaterThanOrEqual(background.bounds.width, background.bounds.height)
                let bitmap = try XCTUnwrap(
                    canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                let attachment = XCTAttachment(
                    data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                    uniformTypeIdentifier: "public.png")
                attachment.name = "Unread badge \(count)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
#endif
