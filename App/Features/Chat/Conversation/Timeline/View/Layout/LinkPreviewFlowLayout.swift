import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// SwiftUI stacks cannot reclaim the thumbnail column midway through a paragraph.
/// Keep TextKit's exclusion-path graph with the measured layout so native timeline
/// rows and compose bridges draw exactly the line fragments that sized the card.
@MainActor
final class LinkPreviewFlowLayout {
    enum Section { case title, description, domain }

    private final class TextRun {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer
        let origin: CGPoint
        let height: CGFloat
        let glyphs: NSRange
        var fragments: [CGRect] {
            var lines: [CGRect] = []
            let origin = origin
            manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                lines.append(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
            return lines
        }
        let section: Section
        private var foregroundColor: BubbleNativeColor?

        init(
            text: String, font: BubbleNativeFont, width: CGFloat, y: CGFloat,
            exclusion: CGRect?, rightToLeft: Bool, lineLimit: Int, section: Section
        ) {
            self.section = section
            origin = CGPoint(x: 0, y: y)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = rightToLeft ? .right : .left
            paragraph.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
            paragraph.lineBreakMode = .byWordWrapping
            storage = NSTextStorage(
                string: text, attributes: [.font: font, .paragraphStyle: paragraph])
            container = NSTextContainer(size: CGSize(width: width, height: 100_000))
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = lineLimit
            container.lineBreakMode = lineLimit > 0 ? .byTruncatingTail : .byWordWrapping
            if let exclusion, exclusion.maxY > y {
                let local = exclusion.offsetBy(dx: 0, dy: -y)
                #if os(macOS)
                    container.exclusionPaths = [NSBezierPath(rect: local)]
                #else
                    container.exclusionPaths = [UIBezierPath(rect: local)]
                #endif
            }
            manager.usesFontLeading = true
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            glyphs = manager.glyphRange(for: container)
            height = ceil(manager.usedRect(for: container).maxY)
        }

        func draw(color: BubbleNativeColor) {
            if foregroundColor != color {
                storage.addAttribute(
                    .foregroundColor, value: color,
                    range: NSRange(location: 0, length: storage.length))
                foregroundColor = color
            }
            manager.drawBackground(forGlyphRange: glyphs, at: origin)
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
    }

    let width: CGFloat
    let height: CGFloat
    let thumbnailFrame: CGRect
    private let runs: [TextRun]

    static func thumbnailFrame(
        width: CGFloat, thumbnailSize: CGFloat, gap: CGFloat,
        titleFont: BubbleNativeFont, rightToLeft: Bool
    ) -> CGRect {
        // Extremely narrow cards still leave at least one text glyph's line region.
        let width = max(1, width)
        let size = min(thumbnailSize, max(0, width - gap - titleFont.pointSize))
        return CGRect(x: rightToLeft ? width - size : 0, y: 0, width: size, height: size)
    }

    init(
        title: String, description: String?, domain: String, width: CGFloat,
        titleFont: BubbleNativeFont, descriptionFont: BubbleNativeFont,
        domainFont: BubbleNativeFont, thumbnailSize: CGFloat, gap: CGFloat = 8,
        rightToLeft: Bool = false, titleLineLimit: Int = 2,
        descriptionLineLimit: Int = 3, sectionSpacing: CGFloat = 2
    ) {
        self.width = max(1, width)
        thumbnailFrame = Self.thumbnailFrame(
            width: self.width, thumbnailSize: thumbnailSize, gap: gap,
            titleFont: titleFont, rightToLeft: rightToLeft)
        let size = thumbnailFrame.width
        let exclusion = CGRect(
            x: rightToLeft ? self.width - size - gap : 0,
            y: 0, width: size + gap, height: size)
        var measured: [TextRun] = []
        let headline = TextRun(
            text: title, font: titleFont, width: self.width, y: 0, exclusion: exclusion,
            rightToLeft: rightToLeft, lineLimit: titleLineLimit, section: .title)
        measured.append(headline)
        var y = headline.height + sectionSpacing
        if let description, description.contains(where: { !$0.isWhitespace }) {
            let summary = TextRun(
                text: description, font: descriptionFont, width: self.width, y: y,
                exclusion: exclusion, rightToLeft: rightToLeft,
                lineLimit: descriptionLineLimit, section: .description)
            measured.append(summary)
            y += summary.height + sectionSpacing
        }
        // A domain is never the truncated tail of a capped title/description.
        // Start below the thumbnail as well, making its complete width available.
        y = max(y, size + sectionSpacing)
        let source = TextRun(
            text: domain, font: domainFont, width: self.width, y: y, exclusion: nil,
            rightToLeft: rightToLeft, lineLimit: 0, section: .domain)
        measured.append(source)
        runs = measured
        height = ceil(max(size, y + source.height))
    }

    func lineFragments(for section: Section) -> [CGRect] {
        runs.first { $0.section == section }?.fragments ?? []
    }

    func draw(foregroundColor: BubbleNativeColor, secondaryColor: BubbleNativeColor) {
        for run in runs {
            run.draw(color: run.section == .domain ? secondaryColor : foregroundColor)
        }
    }
}

#if os(macOS)
    /// Inert drawing surface: the enclosing native control/SwiftUI card owns actions
    /// and accessibility, while this view paints the cached TextKit geometry.
    @MainActor
    class LinkPreviewFlowTextView: NSView {
        var flowLayout: LinkPreviewFlowLayout? { didSet { needsDisplay = true } }
        var foregroundColor: NSColor = .labelColor { didSet { needsDisplay = true } }
        var secondaryColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            flowLayout?.draw(foregroundColor: foregroundColor, secondaryColor: secondaryColor)
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
#else
    @MainActor
    class LinkPreviewFlowTextView: UIView {
        var flowLayout: LinkPreviewFlowLayout? { didSet { setNeedsDisplay() } }
        var foregroundColor: UIColor = .label { didSet { setNeedsDisplay() } }
        var secondaryColor: UIColor = .secondaryLabel { didSet { setNeedsDisplay() } }
        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ rect: CGRect) {
            flowLayout?.draw(foregroundColor: foregroundColor, secondaryColor: secondaryColor)
        }
    }
#endif
