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
                let root = MessageInteractionHost(
                    model: model, context: .init(canWrite: true, isAdmin: true), actions: .init()
                ) { actions in
                    ConversationTimelineView(model: model, loadsInitialAutomatically: false, actions: actions)
                }.preferredColorScheme(dark ? .dark : .light)
                let host = NSHostingController(rootView: root)
                host.sizingOptions = []
                let size = CGSize(width: width, height: 650)
                let window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                    defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentViewController = host
                window.setContentSize(size)
                host.view.frame = CGRect(origin: .zero, size: size)
                window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                await model.loadInitial()
                try await Task.sleep(for: .milliseconds(200))
                host.view.layoutSubtreeIfNeeded()
                let original = try XCTUnwrap(textViews(in: host.view).first)
                let originalWidth = original.bounds.width
                let point = original.convert(CGPoint(x: 10, y: 8), to: nil)
                let event = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: .rightMouseDown, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                NSApp.postEvent(event, atStart: false)
                try await Task.sleep(for: .milliseconds(200))
                host.view.layoutSubtreeIfNeeded()
                let visibleText = textViews(in: host.view)
                XCTAssertEqual(visibleText.count, 2, "Opening the menu should add one read-only message preview.")
                for text in visibleText {
                    XCTAssertEqual(
                        text.bounds.width, originalWidth, accuracy: 1,
                        "The action menu must not force the preview into its narrower width.")
                }
                let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                let image = NSImage(size: size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name =
                    "overlay-\(dark ? "dark" : "light")-\(outgoing ? "outgoing" : "incoming")-\(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }

        private func textViews(in view: NSView) -> [AppKitBubbleTextView] {
            if let text = view as? AppKitBubbleTextView, text.string.contains("The original message") { return [text] }
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
