#if os(macOS)
import AppKit
import XCTest
@testable import chahua_apple

@MainActor
final class MacBubbleTextLayoutTests: XCTestCase {
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
