#if os(macOS)
    import AppKit
    import ChahuaAPI
    import SwiftUI
    import XCTest
    @testable import chahua_apple

    @MainActor
    final class MessageOverlayLayoutTests: XCTestCase {
        func testPreviewPreservesSourceWidthAcrossAppearanceAndSendingSide() async throws {
            for (outgoing, dark, width) in [(false, false, 900.0), (true, true, 900.0), (false, false, 360.0)] {
                let message = try TimelineTestFixtures.message(
                    id: "overlay-size", senderID: outgoing ? 1 : 2, at: 0,
                    text:
                        "The original message keeps its full width. Model: DeepSeek-V4.1-Flash-Expires-On-0910. Reactions and actions remain in a compact, translucent menu."
                )
                let source = OverlayPageSource(page: try TimelineTestFixtures.page([message]))
                let model = ConversationTimelineModel(
                    chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
                    messageStore: ConversationMessageStore())
                await model.loadInitial()
                let host = TimelineViewController(model: model)
                host.configure(
                    actions: .init(), interactionContext: .init(canWrite: true, isAdmin: true),
                    mediaContext: nil, colorScheme: dark ? .dark : .light,
                    headerInset: 0, composerInset: 0, isSplitResizing: false)
                let size = CGSize(width: width, height: 650)
                let window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered,
                    defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentViewController = host
                window.setContentSize(size)
                host.view.frame = CGRect(origin: .zero, size: size)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                defer { host.tearDown(); window.close() }
                let initialDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while textViews(in: host.view).isEmpty, ContinuousClock.now < initialDeadline {
                    host.view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let original = try XCTUnwrap(textViews(in: host.view).first)
                let originalWidth = original.bounds.width
                var ancestor: NSView? = original
                while ancestor != nil, !(ancestor is TimelineRowView) { ancestor = ancestor?.superview }
                let row = try XCTUnwrap(ancestor as? TimelineRowView)
                let action = try XCTUnwrap(row.accessibilityCustomActions()?.first)
                XCTAssertTrue(try XCTUnwrap(action.handler)())
                try await Task.sleep(for: .milliseconds(600))
                let frameView = try XCTUnwrap(window.contentView?.superview)
                frameView.layoutSubtreeIfNeeded()
                let visibleText = textViews(in: frameView)
                XCTAssertEqual(visibleText.count, 2, "Opening the menu should add one read-only message preview.")
                for text in visibleText {
                    XCTAssertEqual(
                        text.bounds.width, originalWidth, accuracy: 1,
                        "The action menu must not force the preview into its narrower width.")
                }
                let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                let image = NSImage(size: frameView.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name =
                    "overlay-\(dark ? "dark" : "light")-\(outgoing ? "outgoing" : "incoming")-\(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)

                // A click over native title-bar chrome must dismiss the preview,
                // not activate the obscured close button or close its window.
                let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
                let titleBarPoint = closeButton.convert(
                    CGPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let click = try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: type, location: titleBarPoint, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
                    NSApp.postEvent(click, atStart: false)
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while textViews(in: frameView).count > 1, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(window.isVisible, "The preview must intercept clicks on covered title-bar controls.")
                XCTAssertEqual(textViews(in: frameView).count, 1, "Clicking covered title-bar chrome must dismiss the preview.")
            }
        }

        private func textViews(in view: NSView) -> [AppKitMessageTextView] {
            if let text = view as? AppKitMessageTextView, text.string.contains("The original message") { return [text] }
            return view.subviews.flatMap { textViews(in: $0) }
        }
    }

    @MainActor
    private final class OverlayPageSource: TimelineMessageSource {
        let page: ListMessagesResponse
        init(page: ListMessagesResponse) { self.page = page }
        func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse { page }
    }
#endif
