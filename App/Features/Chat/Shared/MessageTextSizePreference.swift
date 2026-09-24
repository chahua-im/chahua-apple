import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

enum MessageTextSizePreference {
    static let storageKey = "messageTextSize"
    static let defaultValue = 17
    static let allowedValues = 14...18

    static func clamped(_ value: Int) -> Int {
        min(max(value, allowedValues.lowerBound), allowedValues.upperBound)
    }

    #if os(macOS)
        /// Scale from the platform body font so macOS accessibility text sizing remains intact.
        static func scaledBodySize(_ value: Int) -> CGFloat {
            let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
            return bodySize * CGFloat(clamped(value)) / CGFloat(defaultValue)
        }
    #else
        /// UIKit applies the user's Dynamic Type category to the selected base point size.
        static func scaledBodySize(_ value: Int, compatibleWith traits: UITraitCollection)
            -> CGFloat
        {
            UIFontMetrics(forTextStyle: .body).scaledValue(
                for: CGFloat(clamped(value)), compatibleWith: traits)
        }
    #endif
}
