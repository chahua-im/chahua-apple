#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import chahua_apple

@MainActor
final class MacBubbleTextLayoutTests: XCTestCase {
    func testNativeTextPreservesSelectionAndUsesCurrentLinkActions() throws {
        var opened: [String] = []
        func content(_ prefix: String?) -> MacBubbleTextContent {
            MacBubbleTextContent(
                text: "Hello https://example.com", mentions: [], currentUserID: 1,
                isOutgoing: false,
                action: prefix.map { prefix in { opened.append(prefix + $0.absoluteString) } }
            )
        }
        let host = NSHostingView(rootView: content("first:"))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 100)
        host.layoutSubtreeIfNeeded()
        func textView(in view: NSView) -> MacBubbleTextView? {
            if let text = view as? MacBubbleTextView { return text }
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

    func testShortTextHasCompactIdealWidthWithInlineMetadata() {
        let layout = makeLayout("Hello")
        let size = layout.idealSize
        XCTAssertLessThan(size.width, 180)
        let geometry = layout.geometry(for: size.width)
        XCTAssertTrue(geometry.metadataIsInline)
        XCTAssertGreaterThanOrEqual(geometry.metadataFrame.minX, geometry.lastLineBounds.maxX)
        XCTAssertLessThanOrEqual(geometry.metadataFrame.maxY, geometry.size.height)
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
    func testMetadataAdoptsDarkAppearanceRatherThanItsCreationAppearance() throws {
        var metadata: MacBubbleMetadata?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            metadata = MacBubbleMetadata(time: "12:34", state: nil, isOutgoing: false)
        }
        let view = MacBubbleTextView()
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


    private func makeLayout(_ text: String) -> MacBubbleTextLayout {
        MacBubbleTextLayout(
            attributedText: MacBubbleTextContent.attributedText(
                text: text, mentions: [], currentUserID: 1, isOutgoing: false,
                font: .systemFont(ofSize: 14)
            ),
            metadata: MacBubbleMetadata(time: "12:34", state: nil, isOutgoing: false)
        )
    }
}
#endif
