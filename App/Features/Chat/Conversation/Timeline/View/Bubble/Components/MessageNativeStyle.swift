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
