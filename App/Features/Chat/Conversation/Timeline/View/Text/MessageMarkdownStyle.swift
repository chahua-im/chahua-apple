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

    static func inlineCodeFont(_ surrounding: BubbleNativeFont, size: CGFloat) -> BubbleNativeFont {
        let monospaced = BubbleNativeFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #if os(macOS)
            let traits = NSFontManager.shared.traits(of: surrounding)
            return font(
                monospaced, bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask))
        #else
            let traits = surrounding.fontDescriptor.symbolicTraits
            return font(
                monospaced, bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic)
            )
        #endif
    }

    static func inlineCodeBackground(foreground: BubbleNativeColor) -> BubbleNativeColor {
        translucent(foreground, opacity: 0.10)
    }

    // Resolve the source inside the provider, never in the creating cell's appearance.
    private static func translucent(_ foreground: BubbleNativeColor, opacity: CGFloat)
        -> BubbleNativeColor
    {
        #if os(macOS)
            return NSColor(name: nil) { appearance in
                var resolved = foreground
                appearance.performAsCurrentDrawingAppearance {
                    resolved = foreground.usingColorSpace(.sRGB) ?? foreground
                }
                return resolved.withAlphaComponent(resolved.alphaComponent * opacity)
            }
        #else
            return UIColor { traits in
                let resolved = foreground.resolvedColor(with: traits)
                return resolved.withAlphaComponent(resolved.cgColor.alpha * opacity)
            }
        #endif
    }

    // GitHub/GitHub Dark tokens follow the panel's light/dark appearance.
    static let incomingCode = CodePalette(outgoing: false)
    static let outgoingCode = CodePalette(outgoing: true)

    struct CodePalette {
        let background: BubbleNativeColor
        let headerBackground: BubbleNativeColor
        let headerForeground: BubbleNativeColor
        let foreground: BubbleNativeColor
        private let comment: BubbleNativeColor
        private let keyword: BubbleNativeColor
        private let string: BubbleNativeColor
        private let constant: BubbleNativeColor
        private let title: BubbleNativeColor
        private let variable: BubbleNativeColor
        private let tag: BubbleNativeColor
        private let section: BubbleNativeColor
        private let bullet: BubbleNativeColor
        private let addition: BubbleNativeColor
        private let additionBackground: BubbleNativeColor
        private let deletion: BubbleNativeColor
        private let deletionBackground: BubbleNativeColor

        init(outgoing: Bool) {
            // Light-mode panels share the PWA's primary-tinted neutral surface.
            // Dark-mode sent panels retain their blue treatment and light tokens.
            background = color(light: 0xE4EBF5, dark: outgoing ? 0x163F6B : 0x232B36)
            headerBackground = color(light: 0xCCDCEE, dark: outgoing ? 0x123458 : 0x24354B)
            headerForeground = color(light: 0x1E5690, dark: outgoing ? 0xFFFFFF : 0x79C0FF)
            foreground = color(light: 0x24292E, dark: 0xC9D1D9)
            comment = color(light: 0x6A737D, dark: outgoing ? 0xB2BDCA : 0x8B949E)
            keyword = color(light: 0xD73A49, dark: 0xFF7B72)
            string = color(light: 0x032F62, dark: 0xA5D6FF)
            constant = color(light: 0x005CC5, dark: 0x79C0FF)
            title = color(light: 0x6F42C1, dark: 0xD2A8FF)
            variable = color(light: 0xE36209, dark: 0xFFA657)
            tag = color(light: 0x22863A, dark: 0x7EE787)
            section = color(light: 0x005CC5, dark: outgoing ? 0x79C0FF : 0x1F6FEB)
            bullet = color(light: 0x735C0F, dark: 0xF2CC60)
            addition = color(light: 0x22863A, dark: 0xAFF5B4)
            additionBackground = color(light: 0xF0FFF4, dark: 0x033A16)
            deletion = color(light: 0xB31D28, dark: 0xFFDCD7)
            deletionBackground = color(light: 0xFFEEF0, dark: 0x67060C)
        }

        func applyHighlight(_ kind: String, to value: NSMutableAttributedString, range: NSRange) {
            let root = kind.prefix(while: { $0 != "." })
            let foreground: BubbleNativeColor?
            if kind == "variable.language" || kind.hasPrefix("variable.language.") {
                foreground = keyword
            } else {
                switch root {
                case "doctag", "keyword", "template-tag", "template-variable", "type":
                    foreground = keyword
                case "title": foreground = title
                case "attr", "attribute", "literal", "meta", "number", "operator", "variable",
                    "selector-attr", "selector-class", "selector-id":
                    foreground = constant
                case "regexp", "string": foreground = string
                case "built_in", "symbol": foreground = variable
                case "comment", "code", "formula": foreground = comment
                case "name", "quote", "selector-tag", "selector-pseudo": foreground = tag
                case "subst", "emphasis", "strong": foreground = self.foreground
                case "section": foreground = section
                case "bullet": foreground = bullet
                case "addition": foreground = addition
                case "deletion": foreground = deletion
                default: foreground = nil  // Ignored CSS scopes inherit their enclosing token.
                }
            }
            if let foreground {
                value.addAttribute(.foregroundColor, value: foreground, range: range)
            }
            if root == "addition" || root == "deletion" {
                value.addAttribute(
                    .backgroundColor,
                    value: root == "addition" ? additionBackground : deletionBackground,
                    range: range)
            }
            if root == "section" || root == "strong" || root == "emphasis" {
                value.enumerateAttribute(.font, in: range) { current, subrange, _ in
                    guard let current = current as? BubbleNativeFont else { return }
                    value.addAttribute(
                        .font,
                        value: font(current, bold: root != "emphasis", italic: root == "emphasis"),
                        range: subrange)
                }
            }
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
    let backgroundColor: BubbleNativeColor
    let naturalSize: CGSize
    let codeSize: CGSize
    let headerFont: BubbleNativeFont
    let headerForeground: BubbleNativeColor
    let headerBackground: BubbleNativeColor
    let headerHeight: CGFloat
    let language: String?
    let code: String
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 8

    init(code: String, language: String?, fontSize: CGFloat, isOutgoing: Bool) {
        self.language = language
        self.code = code
        let palette =
            isOutgoing ? MessageMarkdownStyle.outgoingCode : MessageMarkdownStyle.incomingCode
        backgroundColor = palette.background
        headerFont = .systemFont(ofSize: fontSize * 0.75)
        headerForeground = palette.headerForeground
        headerBackground = palette.headerBackground
        headerHeight = max(20, ceil(fontSize * 1.2))
        let highlighted = MarkdownCodeHighlight.supports(language: language)
        let font = BubbleNativeFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(fontSize * 1.4)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineBreakMode = .byClipping
        let value = NSMutableAttributedString(
            string: code.isEmpty ? " " : code,
            attributes: [
                .font: font,
                .foregroundColor: palette.foreground,
                .paragraphStyle: paragraph,
            ])
        if highlighted {
            for span in MarkdownCodeHighlight.spans(code: code, language: language) {
                let range = NSIntersectionRange(
                    span.range, NSRange(location: 0, length: value.length))
                if range.length > 0 {
                    palette.applyHighlight(span.kind, to: value, range: range)
                }
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
        codeSize = CGSize(
            width: ceil(size.width) + Self.horizontalPadding * 2,
            height: ceil(size.height) + Self.verticalPadding * 2)
        // Reserve the header in the attachment itself so measurement, selection and
        // both native renderers keep exactly the same block and following-line bounds.
        let labelWidth = ((language ?? "") as NSString).size(withAttributes: [.font: headerFont])
            .width
        naturalSize = CGSize(
            width: max(codeSize.width, ceil(labelWidth) + 6 + 8 + 24 + 2),
            height: codeSize.height + headerHeight)
        super.init(data: nil, ofType: nil)
        bounds = CGRect(origin: .zero, size: naturalSize)
        #if os(macOS)
            image = NSImage(size: NSSize(width: 1, height: 1))
        #else
            image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        #endif
    }

    required init?(coder: NSCoder) { nil }

    /// Only bounds belong to a layout graph. Highlighting and no-wrap code
    /// measurement are immutable and can be shared by prepared rows and previews.
    func copyForLayout() -> MessageCodeAttachment {
        MessageCodeAttachment(copying: self)
    }

    private init(copying source: MessageCodeAttachment) {
        attributedCode = source.attributedCode
        backgroundColor = source.backgroundColor
        naturalSize = source.naturalSize
        codeSize = source.codeSize
        headerFont = source.headerFont
        headerForeground = source.headerForeground
        headerBackground = source.headerBackground
        headerHeight = source.headerHeight
        language = source.language
        code = source.code
        super.init(data: nil, ofType: nil)
        bounds = CGRect(origin: .zero, size: naturalSize)
        image = source.image
    }

    func fit(width: CGFloat) -> Bool {
        let width = max(1, min(naturalSize.width, width))
        guard bounds.width != width else { return false }
        bounds.size.width = width
        return true
    }
}

/// Per-visible-block feedback, never part of cached Markdown or mutable layout.
/// Native headers use the existing pasteboard conventions; the source is the
/// parser's raw code, not the highlighted string (which pads an empty block).
final class MessageCodeCopyController {
    enum Status {
        case ready, copied, failed

        var symbol: String {
            switch self {
            case .ready: "doc.on.doc"
            case .copied: "checkmark"
            case .failed: "exclamationmark.triangle"
            }
        }

        var label: String {
            switch self {
            case .ready: AppLanguage.localized("Copy")
            case .copied: AppLanguage.localized("Copied")
            case .failed: AppLanguage.localized("Failed")
            }
        }
    }

    static let feedbackDuration: TimeInterval = 3
    private(set) var status = Status.ready
    var isEnabled = true
    var onChange: (() -> Void)?
    private var timer: Timer?

    func copy(_ code: String) {
        guard isEnabled else { return }
        timer?.invalidate()
        timer = nil
        #if os(macOS)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(code, forType: .string) else {
                status = .failed
                onChange?()
                return
            }
        #else
            UIPasteboard.general.string = code
        #endif
        status = .copied
        onChange?()
        let timer = Timer(timeInterval: Self.feedbackDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        status = .ready
        onChange?()
    }

    deinit { timer?.invalidate() }
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
