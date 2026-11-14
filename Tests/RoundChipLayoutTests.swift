import SwiftUI
import XCTest

@testable import chahua_apple

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
final class RoundChipLayoutTests: XCTestCase {
    func testSingleGraphemesStaySquareAndLongLabelsOnlyGrowHorizontally() {
        for fontSize: CGFloat in [11, 24, 40] {
            for label in ["1", "@", "W", "👨‍👩‍👧‍👦", "11", "99+", "٩٩٩"] {
                let content = Text(label).font(.system(size: fontSize))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .frame(minHeight: 18).fixedSize()
                let textSize = measure(content)
                let chipSize = measure(
                    RoundChipLayout(isCircular: label.count == 1) { content }.fixedSize())
                XCTAssertGreaterThanOrEqual(chipSize.width, textSize.width)
                XCTAssertGreaterThanOrEqual(chipSize.height, textSize.height)
                if label.count == 1 {
                    XCTAssertEqual(chipSize.width, chipSize.height, accuracy: 0.01)
                } else {
                    XCTAssertGreaterThanOrEqual(chipSize.width, chipSize.height)
                    XCTAssertEqual(chipSize.height, textSize.height, accuracy: 0.01)
                }
            }
        }
    }

    private func measure(_ view: some View) -> CGSize {
        #if os(macOS)
            NSHostingView(rootView: view).fittingSize
        #else
            UIHostingController(rootView: view).sizeThatFits(
                in: CGSize(width: 1000, height: 1000))
        #endif
    }
}
