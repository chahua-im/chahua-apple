import ChahuaMarkdown
import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Native fonts and colors are shared by measurement and display, including the
/// independently scrolling code TextKit views. SwiftUI cannot embed a selectable,
/// no-wrap horizontal text region inside another selectable TextKit document.
enum MessageMarkdownStyle {
    static func font(_ font: BubbleNativeFont, bold: Bool = false, italic: Bool = false)
        -> BubbleNativeFont
    {
        #if os(macOS)
            var traits = NSFontManager.shared.traits(of: font)
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            return NSFontManager.shared.convert(font, toHaveTrait: traits)
        #else
            var traits = font.fontDescriptor.symbolicTraits
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            return font.fontDescriptor.withSymbolicTraits(traits).map {
                UIFont(descriptor: $0, size: font.pointSize)
            } ?? font
        #endif
    }

    static let codeBackground = color(light: 0xF6F8FA, dark: 0x161B22)
    static let codeForeground = color(light: 0x24292F, dark: 0xC9D1D9)
    private static let comment = color(light: 0x6E7781, dark: 0x8B949E)
    private static let keyword = color(light: 0xCF222E, dark: 0xFF7B72)
    private static let string = color(light: 0x0A3069, dark: 0xA5D6FF)
    private static let number = color(light: 0x0550AE, dark: 0x79C0FF)
    private static let title = color(light: 0x8250DF, dark: 0xD2A8FF)
    private static let variable = color(light: 0x953800, dark: 0xFFA657)

    static func highlight(_ kind: String) -> BubbleNativeColor {
        switch kind.prefix(while: { $0 != "." }) {
        case "comment", "quote": return comment
        case "keyword", "selector-tag", "literal", "deletion": return keyword
        case "string", "regexp", "addition", "meta-string": return string
        case "number", "built_in", "type", "symbol", "bullet", "attr", "attribute": return number
        case "title", "section", "function": return title
        case "variable", "template-variable", "params": return variable
        default: return codeForeground
        }
    }

    nonisolated private static func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (
            CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
            CGFloat(hex & 255) / 255
        )
    }

    static func color(light: UInt32, dark: UInt32) -> BubbleNativeColor {
        #if os(macOS)
            return NSColor(name: nil) { appearance in
                let value =
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                let (r, g, b) = components(value)
                return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            }
        #else
            return UIColor { traits in
                let (r, g, b) = components(traits.userInterfaceStyle == .dark ? dark : light)
                return UIColor(red: r, green: g, blue: b, alpha: 1)
            }
        #endif
    }
}

final class MessageCodeAttachment: NSTextAttachment {
    let attributedCode: NSAttributedString
    let naturalSize: CGSize
    let language: String?
    let code: String
    static let padding: CGFloat = 10

    init(code: String, language: String?, fontSize: CGFloat) {
        self.language = language
        self.code = code
        let font = BubbleNativeFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(fontSize * 1.4)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineBreakMode = .byClipping
        let value = NSMutableAttributedString(
            string: code.isEmpty ? " " : code,
            attributes: [
                .font: font, .foregroundColor: MessageMarkdownStyle.codeForeground,
                .paragraphStyle: paragraph,
            ])
        for span in MarkdownCodeHighlight.spans(code: code, language: language) {
            let range = NSIntersectionRange(span.range, NSRange(location: 0, length: value.length))
            if range.length > 0 {
                value.addAttribute(
                    .foregroundColor, value: MessageMarkdownStyle.highlight(span.kind), range: range
                )
            }
        }
        attributedCode = value
        // Use the same TextKit 1 graph as the nested platform views, without wrapping.
        let storage = NSTextStorage(attributedString: value)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 1_000_000, height: 1_000_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var size = manager.usedRect(for: container).size
        if code.last == "\n" { size.height = max(size.height, manager.extraLineFragmentRect.maxY) }
        naturalSize = CGSize(
            width: ceil(size.width) + Self.padding * 2, height: ceil(size.height) + Self.padding * 2
        )
        super.init(data: nil, ofType: nil)
        bounds = CGRect(origin: .zero, size: naturalSize)
        #if os(macOS)
            image = NSImage(size: NSSize(width: 1, height: 1))
        #else
            image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        #endif
    }

    required init?(coder: NSCoder) { nil }

    func fit(width: CGFloat) -> Bool {
        let width = max(1, min(naturalSize.width, width))
        guard bounds.width != width else { return false }
        bounds.size.width = width
        return true
    }
}

/// A weak-owner callback at each callsite prevents a timer retaining recycled cells.
/// Hosts stop it off-window, in the background, and when no concealed runs remain.
final class MessageSpoilerAnimator {
    private var timer: Timer?
    func start(action: @escaping @MainActor @Sendable () -> Void) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 24, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    deinit { timer?.invalidate() }
}
