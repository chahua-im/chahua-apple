#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import XCTest
@testable import chahua_apple

@MainActor
final class MessageTextLayoutTests: XCTestCase {
    #if os(macOS)
    func testNativeTextPreservesSelectionAndUsesCurrentLinkActions() throws {
        var opened: [String] = []
        func content(_ prefix: String?) -> MessageTextContent {
            MessageTextContent(
                text: "Hello https://example.com", mentions: [], currentUserID: 1,
                isOutgoing: false,
                action: prefix.map { prefix in { opened.append(prefix + $0.absoluteString) } }
            )
        }
        let host = NSHostingView(rootView: content("first:"))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 100)
        host.layoutSubtreeIfNeeded()
        func textView(in view: NSView) -> AppKitMessageTextView? {
            if let text = view as? AppKitMessageTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let text = try XCTUnwrap(textView(in: host))
        let link = try XCTUnwrap(text.textStorage?.attribute(.link, at: 6, effectiveRange: nil))
        text.setSelectedRange(NSRange(location: 0, length: 5))
        _ = text.delegate?.textView?(text, clickedOnLink: link, at: 6)
        XCTAssertEqual(opened, ["first:https://example.com"])

        host.rootView = content("replacement:")
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))
        _ = text.delegate?.textView?(text, clickedOnLink: link, at: 6)
        XCTAssertEqual(opened, ["first:https://example.com", "replacement:https://example.com"])

        host.rootView = content(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(text.textStorage?.attribute(.link, at: 6, effectiveRange: nil))
        _ = text.delegate?.textView?(text, clickedOnLink: link, at: 6)
        XCTAssertEqual(opened, ["first:https://example.com", "replacement:https://example.com"])
        XCTAssertEqual(text.string, "Hello https://example.com")
    }

    func testHostedLinkHoverUsesHandWithoutDisablingTextSelection() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let previousCursor = NSCursor.current
        defer {
            window.close()
            previousCursor.set()
        }
        let host = TimelineBubbleHostingView(rootView:
            MessageTextContent(
                text: "Hello https://example.com", mentions: [], currentUserID: 1,
                isOutgoing: false, action: { _ in }
            )
            .padding(12)
            .onHover { _ in }
        )
        host.sizingOptions = []
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func textView(in view: NSView) -> AppKitMessageTextView? {
            if let text = view as? AppKitMessageTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let text = try XCTUnwrap(textView(in: host))
        text.layoutSubtreeIfNeeded()
        text.setSelectedRange(NSRange(location: 0, length: 5))

        func hover(_ characterIndex: Int) throws {
            let layout = text.contentLayout
            let glyphs = layout.layoutManager.glyphRange(
                forCharacterRange: NSRange(location: characterIndex, length: 1), actualCharacterRange: nil
            )
            let rect = layout.layoutManager.boundingRect(forGlyphRange: glyphs, in: layout.textContainer)
            let point = text.convert(
                NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y),
                to: nil
            )
            let event = try XCTUnwrap(NSEvent.enterExitEvent(
                with: .cursorUpdate, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            ))
            host.cursorUpdate(with: event)
        }

        try hover(8)
        XCTAssertEqual(NSCursor.current, .pointingHand)
        try hover(1)
        XCTAssertEqual(NSCursor.current, .iBeam)
        try hover(text.string.utf16.count - 1)
        XCTAssertEqual(NSCursor.current, .pointingHand)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))

        text.textStorage?.removeAttribute(.link, range: NSRange(location: 0, length: text.string.utf16.count))
        try hover(8)
        XCTAssertEqual(NSCursor.current, .iBeam)
    }
    #else
    func testUIKitSelectionSurvivesActionReplacementAndDisabledLinksCannotEscape() async throws {
        var opened: [String] = []
        func content(_ prefix: String?) -> MessageTextContent {
            MessageTextContent(
                text: "Hello https://example.com @[uid:2]", mentions: [], currentUserID: 1,
                isOutgoing: false,
                action: prefix.map { prefix in { opened.append(prefix + $0.absoluteString) } },
                mentionAction: prefix.map { prefix in { opened.append(prefix + "mention:\($0)") } },
                metadata: MessageMetadata(time: "12:34", state: nil, isOutgoing: false)
            )
        }
        let host = UIHostingController(rootView: content("first:"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func settle() async throws {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
        }
        try await settle()
        func textView(in view: UIView) -> UIKitMessageTextView? {
            if let text = view as? UIKitMessageTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let text = try XCTUnwrap(textView(in: host.view))
        let link = try XCTUnwrap(URL(string: "https://example.com"))
        let mention = try XCTUnwrap(URL(string: "chahua-mention://2"))
        let linkRange = (text.text as NSString).range(of: link.absoluteString)
        let mentionRange = (text.text as NSString).range(of: "@User 2")
        let expectedText = "Hello https://example.com \u{2002}@User 2\u{2002}"
        XCTAssertEqual(text.text, expectedText, "Timestamp metadata must not enter the selectable text.")
        text.selectedRange = NSRange(location: 0, length: 5)
        XCTAssertEqual(text.delegate?.textView?(text, shouldInteractWith: link, in: linkRange, interaction: .presentActions), false)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(text.delegate?.textView?(text, shouldInteractWith: link, in: linkRange, interaction: .invokeDefaultAction), false)
        XCTAssertEqual(text.delegate?.textView?(text, shouldInteractWith: mention, in: mentionRange, interaction: .invokeDefaultAction), false)
        XCTAssertEqual(opened, ["first:https://example.com", "first:mention:2"])

        host.rootView = content("replacement:")
        try await settle()
        XCTAssertEqual(text.selectedRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(text.delegate?.textView?(text, shouldInteractWith: link, in: linkRange, interaction: .invokeDefaultAction), false)
        XCTAssertEqual(text.delegate?.textView?(text, shouldInteractWith: mention, in: mentionRange, interaction: .invokeDefaultAction), false)
        let expectedActions = ["first:https://example.com", "first:mention:2", "replacement:https://example.com", "replacement:mention:2"]
        XCTAssertEqual(opened, expectedActions)

        host.rootView = content(nil)
        try await settle()
        XCTAssertEqual(text.delegate?.textView?(text, shouldInteractWith: link, in: linkRange, interaction: .invokeDefaultAction), false)
        XCTAssertEqual(text.delegate?.textView?(text, shouldInteractWith: mention, in: mentionRange, interaction: .invokeDefaultAction), false)
        XCTAssertEqual(opened, expectedActions)
        XCTAssertEqual(text.selectedRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(text.text, expectedText)
    }
    #endif

    func testShortTextHasCompactIdealWidthWithInlineMetadata() {
        let layout = makeLayout("Hello")
        let size = layout.idealSize
        XCTAssertLessThan(size.width, 180)
        let geometry = layout.geometry(for: size.width)
        XCTAssertTrue(geometry.metadataIsInline)
        XCTAssertGreaterThanOrEqual(geometry.metadataFrame.minX, geometry.lastLineBounds.maxX)
        XCTAssertLessThanOrEqual(geometry.metadataFrame.maxY, geometry.size.height)
    }

    func testMetadataUsesWidthAssignedByWiderBubbleHeader() {
        let layout = makeLayout("Hi")
        let ideal = layout.idealSize
        let assignedWidth = ideal.width + 100
        let fitted = layout.fittingSize(width: assignedWidth)
        let geometry = layout.geometry(for: fitted.width)
        XCTAssertEqual(geometry.metadataFrame.maxX, assignedWidth, accuracy: 0.5)
        XCTAssertTrue(geometry.metadataIsInline)
        XCTAssertEqual(layout.fittingSize(width: nil).width, ideal.width, accuracy: 0.5)
    }

    func testMetadataMovesBelowCrowdedFinalLineAndBackAfterResize() {
        let layout = makeLayout("A final line that nearly fills its container")
        let ideal = layout.idealSize
        let narrow = layout.geometry(for: ideal.width - 10)
        XCTAssertFalse(narrow.metadataIsInline)
        XCTAssertGreaterThanOrEqual(narrow.metadataFrame.minY, narrow.bodyBounds.maxY)
        let wide = layout.geometry(for: ideal.width)
        XCTAssertTrue(wide.metadataIsInline)
        XCTAssertLessThan(wide.size.height, narrow.size.height)
        XCTAssertLessThanOrEqual(wide.metadataFrame.maxX, wide.size.width)
    }
    #if os(macOS)
    func testMetadataAdoptsDarkAppearanceRatherThanItsCreationAppearance() throws {
        var metadata: MessageMetadata?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            metadata = MessageMetadata(time: "12:34", state: nil, isOutgoing: false)
        }
        let view = AppKitMessageTextView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.drawsBackground = true
        view.backgroundColor = .black
        view.contentLayout.update(attributedText: NSAttributedString(string: ""), metadata: metadata)
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 24)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var brightest: CGFloat = 0
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                brightest = max(brightest, color.redComponent, color.greenComponent, color.blueComponent)
            }
        }
        XCTAssertGreaterThan(brightest, 0.4, "Metadata created outside a drawing pass must resolve its color in the displaying view.")
    }
    #endif

    private func makeLayout(_ text: String) -> MessageTextLayout {
        MessageTextLayout(
            attributedText: MessageTextContent.attributedText(
                text: text, mentions: [], currentUserID: 1, isOutgoing: false,
                font: .systemFont(ofSize: 14)
            ),
            metadata: MessageMetadata(time: "12:34", state: nil, isOutgoing: false)
        )
    }
}
