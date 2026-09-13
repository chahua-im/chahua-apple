#if os(macOS)
import AppKit
typealias BubbleNativeFont = NSFont
typealias BubbleNativeColor = NSColor
typealias BubbleNativeImage = NSImage
#else
import UIKit
typealias BubbleNativeFont = UIFont
typealias BubbleNativeColor = UIColor
typealias BubbleNativeImage = UIImage
#endif

var bubbleLabelColor: BubbleNativeColor {
    #if os(macOS)
    .labelColor
    #else
    .label
    #endif
}

enum MessageNativeSymbol {
    static func size(_ name: String, fontSize: CGFloat, semibold: Bool) -> CGSize {
        #if os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: fontSize, weight: semibold ? .semibold : .regular))?.size ?? .zero
        #else
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize, weight: semibold ? .semibold : .regular))?.size ?? .zero
        #endif
    }
}
