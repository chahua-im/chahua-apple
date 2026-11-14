#if os(macOS)
    import AppKit
    import ChahuaAPI
    import SwiftUI
    import XCTest
    @testable import chahua_apple

    @MainActor
    final class MessageOverlayLayoutTests: XCTestCase {
        func testImageViewerBlocksMessageContextClicksUntilDismissed() async throws {
            let previousTickSource = TimelineDisplayScheduler.tickSource
            TimelineDisplayScheduler.tickSource = .runLoop
            defer { TimelineDisplayScheduler.tickSource = previousTickSource }
            let message = try TimelineTestFixtures.message(
                id: 1, senderID: 2, at: 0, text: "The original message behind the viewer")
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: true,
                source: OverlayPageSource(page: try TimelineTestFixtures.page([message])),
                messageStore: ConversationMessageStore())
            await model.loadInitial()
            let host = NSHostingController(
                rootView: ConversationTimelineView(
                    model: model, loadsInitialAutomatically: false,
                    interactionContext: .init(canWrite: true, isAdmin: true)
                ).modifier(TimelineInteractionOverlayRoot()))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(CGSize(width: 800, height: 600))
            host.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            window.makeKeyAndOrderFront(nil)
            defer {
                window.contentViewController = nil
                window.close()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while textViews(in: host.view).isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                host.view.layoutSubtreeIfNeeded()
            }
            let text = try XCTUnwrap(textViews(in: host.view).first)
            let clickPoint = text.convert(
                CGPoint(x: text.bounds.midX, y: text.bounds.midY), to: nil)
            let gallery = try XCTUnwrap(
                MessageImageGallery(
                    messageID: "image",
                    items: [
                        .init(
                            id: "image", url: nil, contentType: "image/png",
                            fileName: "image.png", width: 16, height: 16)
                    ],
                    selectedID: "image"))
            let viewer = MessageImageDetailMacView(
                gallery: gallery, mediaContext: nil, onDismiss: {})
            viewer.frame = host.view.bounds
            host.view.addSubview(viewer)
            viewer.layoutSubtreeIfNeeded()
            defer { viewer.invalidate() }
            func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws {
                let event = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: clickPoint, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1))
                NSApp.postEvent(event, atStart: false)
            }
            let frame = try XCTUnwrap(window.contentView?.superview)
            let copyLabel = MessageMenuAction.copy.label(hasAttachments: false)
            for (type, modifiers) in [
                (NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()),
                (.leftMouseDown, .control),
            ] {
                try click(type, modifiers: modifiers)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(buttons(in: frame).contains { $0.accessibilityLabel() == copyLabel })
            }
            viewer.invalidate()
            viewer.removeFromSuperview()
            try click(.rightMouseDown)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(buttons(in: frame).contains { $0.accessibilityLabel() == copyLabel })
        }

        func testMenuKeepsMessageInPlaceAndDismissesOnOutsideClick() async throws {
            let previousTickSource = TimelineDisplayScheduler.tickSource
            TimelineDisplayScheduler.tickSource = .runLoop
            defer { TimelineDisplayScheduler.tickSource = previousTickSource }
            for (outgoing, dark, width, hasWindowChrome) in [
                (false, false, 900.0, true), (true, true, 900.0, true),
                (false, false, 360.0, true), (false, false, 560.0, false),
            ] {
                let message = try TimelineTestFixtures.message(
                    id: 1, senderID: outgoing ? 1 : 2, at: 0,
                    text:
                        "The original message keeps its full width. Model: DeepSeek-V4.1-Flash-Expires-On-0910. Reactions and actions remain in a compact, translucent menu."
                )
                let source = OverlayPageSource(page: try TimelineTestFixtures.page([message]))
                let model = ConversationTimelineModel(
                    chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
                    messageStore: ConversationMessageStore())
                await model.loadInitial()
                let timeline = ConversationTimelineView(
                    model: model, loadsInitialAutomatically: false,
                    interactionContext: .init(canWrite: true, isAdmin: true)
                )
                .preferredColorScheme(dark ? .dark : .light)
                let host = NSHostingController(
                    rootView: Group {
                        if hasWindowChrome {
                            timeline.modifier(MacConversationWindowChrome())
                        } else {
                            timeline.modifier(TimelineInteractionOverlayRoot())
                        }
                    })
                let size = CGSize(width: width, height: 650)
                let window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable], backing: .buffered,
                    defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentViewController = host
                window.setContentSize(size)
                host.view.frame = CGRect(origin: .zero, size: size)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                defer {
                    window.contentViewController = nil
                    window.close()
                }
                host.view.layoutSubtreeIfNeeded()
                let loadDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                while textViews(in: host.view).isEmpty, ContinuousClock.now < loadDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                    host.view.layoutSubtreeIfNeeded()
                }
                let original = try XCTUnwrap(textViews(in: host.view).first)
                let frameView = try XCTUnwrap(window.contentView?.superview)
                let originalFrame = original.convert(original.bounds, to: frameView)
                var ancestor: NSView? = original
                while ancestor != nil, !(ancestor is TimelineRowView) {
                    ancestor = ancestor?.superview
                }
                let row = try XCTUnwrap(ancestor as? TimelineRowView)
                let action = try XCTUnwrap(row.accessibilityCustomActions()?.first)
                XCTAssertTrue(try XCTUnwrap(action.handler)())
                let copyLabel = MessageMenuAction.copy.label(hasAttachments: false)
                frameView.layoutSubtreeIfNeeded()
                let copyAction = try XCTUnwrap(
                    buttons(in: frameView).first { $0.accessibilityLabel() == copyLabel },
                    "Missing Copy action: outgoing=\(outgoing), dark=\(dark), width=\(width)")
                XCTAssertEqual(
                    textViews(in: frameView).count, 1,
                    "Desktop menus must not duplicate the message.")
                XCTAssertEqual(
                    original.convert(original.bounds, to: frameView), originalFrame,
                    "Opening the menu must not move or resize the message.")
                XCTAssertTrue(copyAction.isEnabled)
                // The supported content hierarchy must receive clicks on menu actions.
                let content = try XCTUnwrap(window.contentView)
                let copyPoint = copyAction.convert(
                    CGPoint(x: copyAction.bounds.midX, y: copyAction.bounds.midY),
                    to: content.superview)
                let hit = content.hitTest(copyPoint)
                XCTAssertTrue(hit === copyAction || hit?.isDescendant(of: copyAction) == true)

                // A click over native title-bar chrome dismisses the menu,
                // without also activating the close button.
                let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
                let titleBarPoint = closeButton.convert(
                    CGPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let click = try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: type, location: titleBarPoint, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber,
                            context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
                    NSApp.postEvent(click, atStart: false)
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while buttons(in: frameView).contains(where: {
                    $0.accessibilityLabel() == copyLabel
                }), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(
                    window.isVisible, "The outside click must not activate the window control.")
                XCTAssertFalse(
                    buttons(in: frameView).contains {
                        $0.accessibilityLabel() == copyLabel
                    }, "Clicking title-bar chrome must dismiss the menu.")
            }
        }

        private func textViews(in view: NSView) -> [AppKitMessageTextView] {
            if let text = view as? AppKitMessageTextView,
                text.string.contains("The original message")
            {
                return [text]
            }
            return view.subviews.flatMap { textViews(in: $0) }
        }

        private func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
    }

    @MainActor
    private final class OverlayPageSource: TimelineMessageSource {
        let page: ListMessagesResponse
        init(page: ListMessagesResponse) { self.page = page }
        func fetchMessages(chatID: String, query: ListMessagesQuery) async throws
            -> ListMessagesResponse
        { page }
    }
#endif
