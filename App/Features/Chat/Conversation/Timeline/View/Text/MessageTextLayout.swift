import CoreText
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

struct MessageCodeGeometry: Equatable {
    let characterIndex: Int
    let frame: CGRect
}

struct MessageTextGeometry: Equatable {
    let size: CGSize
    let containerWidth: CGFloat
    let bodyBounds: CGRect
    let lastLineBounds: CGRect
    let visibleBounds: CGRect
    let metadataFrame: CGRect
    let metadataIsInline: Bool
    let codeBlocks: [MessageCodeGeometry]
}

/// The engine measures row geometry; selectable native text views install that geometry
/// to reproduce its line breaks. Metadata is drawn outside the text storage.
final class MessageTextLayout {
    let storage = NSTextStorage()
    let layoutManager = MessageMentionLayoutManager()
    let textContainer = NSTextContainer(size: .zero)
    private(set) var metadata: MessageMetadata?
    private(set) var assignedGeometry: MessageTextGeometry?
    private var cachedGeometry: MessageTextGeometry?
    private var cachedIdealSize: CGSize?

    init(
        attributedText: NSAttributedString = NSAttributedString(string: ""),
        metadata: MessageMetadata? = nil
    ) {
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        update(attributedText: attributedText, metadata: metadata)
    }

    @discardableResult
    func update(attributedText: NSAttributedString? = nil, metadata: MessageMetadata?) -> Bool {
        var textChanged = false
        if let attributedText, !storage.isEqual(to: attributedText) {
            storage.setAttributedString(attributedText)
            layoutManager.resetSpoilerParticles()
            textChanged = true
        }
        let geometryChanged = textChanged || self.metadata?.size != metadata?.size
        if geometryChanged {
            cachedGeometry = nil
            cachedIdealSize = nil
        }
        self.metadata = metadata
        return geometryChanged
    }
    var assignedSize: CGSize { assignedGeometry?.size ?? .zero }

    /// Installs the engine's final geometry without measuring the visible text view.
    @discardableResult
    func install(geometry: MessageTextGeometry) -> Bool {
        let changed = assignedGeometry != geometry
        fitCodeBlocks(width: geometry.containerWidth)
        let containerSize = CGSize(width: geometry.containerWidth, height: .greatestFiniteMagnitude)
        if textContainer.size != containerSize {
            textContainer.size = containerSize
        }
        assignedGeometry = geometry
        cachedGeometry = geometry
        if changed { cachedIdealSize = nil }
        return changed
    }

    private var metadataGap: CGFloat {
        let font =
            storage.length > 0
            ? storage.attribute(.bubbleBodyFont, at: 0, effectiveRange: nil) as? BubbleNativeFont
                ?? storage.attribute(.font, at: 0, effectiveRange: nil) as? BubbleNativeFont : nil
        return ("0" as NSString).size(withAttributes: [
            .font: font ?? BubbleNativeFont.preferredFont(forTextStyle: .body)
        ]).width * 1.5
    }

    var idealSize: CGSize {
        if let cachedIdealSize { return cachedIdealSize }
        let geometry = geometry(for: 1_000_000)
        let width = max(
            geometry.bodyBounds.maxX + (metadata?.textTrailingOutset ?? 0),
            geometry.lastLineBounds.maxX + (storage.length > 0 && metadata != nil ? metadataGap : 0)
                + (metadata?.size.width ?? 0))
        let size = self.geometry(for: max(1, ceil(width))).size
        cachedIdealSize = size
        return size
    }

    func fittingSize(width: CGFloat?) -> CGSize {
        geometry(for: width ?? idealSize.width).size
    }

    /// Concealed text remains in storage for stable layout, but is not a native
    /// selection/export target. Clamp at the nearest concealed run in the user's
    /// selection direction; ordinary text and independently selectable code retain
    /// native selection behavior. Hosts also apply this when a spoiler is hidden.
    func selectableRange(_ proposed: NSRange, previous: NSRange) -> NSRange {
        guard proposed.location != NSNotFound else { return proposed }
        let location = min(proposed.location, storage.length)
        var result = NSRange(
            location: location, length: min(proposed.length, storage.length - location))
        guard storage.length > 0 else { return result }
        storage.enumerateAttribute(.bubbleSpoiler, in: NSRange(location: 0, length: storage.length))
        { _, range, _ in
            guard layoutManager.isConcealed(at: range.location) else { return }
            if result.length == 0 {
                if result.location > range.location && result.location < NSMaxRange(range) {
                    let before = result.location - range.location
                    let after = NSMaxRange(range) - result.location
                    result.location = before <= after ? range.location : NSMaxRange(range)
                }
            } else if NSIntersectionRange(result, range).length > 0 {
                let end = NSMaxRange(result)
                if result.location >= range.location
                    || (previous.location != NSNotFound && previous.location >= NSMaxRange(range))
                {
                    result = NSRange(
                        location: NSMaxRange(range), length: max(0, end - NSMaxRange(range)))
                } else {
                    result.length = max(0, range.location - result.location)
                }
            }
        }
        return result
    }

    var accessibilityText: String {
        guard storage.length > 0 else { return "" }
        let text = storage.string as NSString
        var result = ""
        var previousHiddenIDs: [Int]?
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) {
            attributes, range, _ in
            if layoutManager.isConcealed(at: range.location) {
                let ids = attributes[.bubbleSpoiler] as? [Int]
                if ids != previousHiddenIDs { result += AppLanguage.localized("Spoiler") }
                previousHiddenIDs = ids
            } else {
                previousHiddenIDs = nil
                if let code = attributes[.bubbleCodeBlock] as? MessageCodeAttachment {
                    result += code.code
                } else {
                    result += text.substring(with: range)
                }
            }
        }
        return result
    }

    private func fitCodeBlocks(width: CGFloat) {
        guard storage.length > 0 else { return }
        storage.enumerateAttribute(
            .bubbleCodeBlock, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let attachment = value as? MessageCodeAttachment else { return }
            let paragraph =
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle
            guard
                attachment.fit(
                    width: width
                        - max(paragraph?.headIndent ?? 0, paragraph?.firstLineHeadIndent ?? 0))
            else { return }
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    var codeBlocks: [(MessageCodeGeometry, MessageCodeAttachment)] {
        guard let geometry = assignedGeometry else { return [] }
        return geometry.codeBlocks.compactMap { block in
            guard block.characterIndex < storage.length,
                let attachment = storage.attribute(
                    .bubbleCodeBlock, at: block.characterIndex, effectiveRange: nil)
                    as? MessageCodeAttachment
            else { return nil }
            return (block, attachment)
        }
    }

    func geometry(for proposedWidth: CGFloat) -> MessageTextGeometry {
        let width = proposedWidth.isFinite ? max(1, proposedWidth) : 1_000_000
        if let cachedGeometry, cachedGeometry.size.width == width { return cachedGeometry }
        // Only the footer extends into the right inset; body text keeps its own wrap width.
        let outset = min(metadata?.textTrailingOutset ?? 0, max(0, width - 1))
        let containerWidth = width - outset
        fitCodeBlocks(width: containerWidth)
        textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        var bodyBounds =
            storage.length == 0 ? CGRect.zero : layoutManager.usedRect(for: textContainer)
        var lastLine = CGRect.zero
        let glyphs = layoutManager.glyphRange(for: textContainer)
        // Native text views may extend used line fragments to the container edge
        // for selection. Those rectangles are not the intrinsic glyph width.
        let text = storage.string as NSString
        var maximumGlyphX: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
            var inkRange = range
            while inkRange.length > 0 {
                let character = text.character(
                    at: self.layoutManager.characterIndexForGlyph(at: NSMaxRange(inkRange) - 1))
                guard
                    character == 10 || character == 13 || character == 0x2028 || character == 0x2029
                else { break }
                inkRange.length -= 1
            }
            let ink =
                inkRange.length > 0
                ? self.layoutManager.boundingRect(forGlyphRange: inkRange, in: self.textContainer)
                : .zero
            maximumGlyphX = max(maximumGlyphX, ink.maxX)
            lastLine = CGRect(
                x: used.minX, y: used.minY, width: max(0, ink.maxX - used.minX), height: used.height
            )
        }
        bodyBounds.size.width = maximumGlyphX
        if storage.string.last == "\n" || storage.string.last == "\r" {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                lastLine = CGRect(x: 0, y: extra.minY, width: 0, height: extra.height)
                bodyBounds.size.height = max(bodyBounds.maxY, extra.maxY) - bodyBounds.minY
            }
        }
        let naturalMetadata = metadata?.size ?? .zero
        let scale = naturalMetadata.width > 0 ? min(1, width / naturalMetadata.width) : 1
        let metadataSize = CGSize(
            width: naturalMetadata.width * scale, height: naturalMetadata.height * scale)
        let inline =
            metadata != nil && storage.length > 0
            && lastLine.maxX + metadataGap + metadataSize.width <= width
        let metadataY =
            inline
            ? max(
                lastLine.minY,
                lastLine.maxY - metadataSize.height + (metadata?.textBaselineDrop ?? 0))
            : ceil(bodyBounds.maxY)
        let metadataFrame =
            metadata == nil
            ? CGRect.zero
            : CGRect(
                x: width - metadataSize.width, y: metadataY, width: metadataSize.width,
                height: metadataSize.height)
        let glyphBounds =
            glyphs.length > 0 && bodyBounds.height <= lastLine.height + 0.5
            ? layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer) : bodyBounds
        let visibleBounds = metadata == nil ? glyphBounds : glyphBounds.union(metadataFrame)
        var codeBlocks: [MessageCodeGeometry] = []
        if storage.length > 0 {
            storage.enumerateAttribute(
                .bubbleCodeBlock, in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                guard let attachment = value as? MessageCodeAttachment else { return }
                let glyph = layoutManager.glyphRange(
                    forCharacterRange: range, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyph, in: textContainer)
                codeBlocks.append(
                    MessageCodeGeometry(
                        characterIndex: range.location,
                        frame: CGRect(
                            x: rect.minX, y: rect.minY, width: attachment.bounds.width,
                            height: attachment.bounds.height)))
            }
        }
        let result = MessageTextGeometry(
            size: CGSize(width: width, height: ceil(max(bodyBounds.maxY, metadataFrame.maxY))),
            containerWidth: containerWidth,
            bodyBounds: bodyBounds, lastLineBounds: lastLine, visibleBounds: visibleBounds,
            metadataFrame: metadataFrame, metadataIsInline: inline, codeBlocks: codeBlocks
        )
        cachedGeometry = result
        return result
    }

    /// TextKit's glyph rectangles include line leading. Core Text exposes the actual
    /// painted bounds, including fallback fonts and color emoji, relative to that baseline.
    func singleLineInkBounds() -> CGRect {
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(for: textContainer)
        guard glyphs.length > 0 else { return .zero }
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphs.location, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyphs.location)
        let line = CTLineCreateWithAttributedString(storage)
        let ink = CTLineGetImageBounds(line, nil)
        // Markdown can produce a whitespace-only run with no painted glyphs.
        guard !ink.isNull, !ink.isEmpty else {
            return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        }
        return CGRect(
            x: fragment.minX + location.x + ink.minX,
            y: fragment.minY + location.y - ink.maxY,
            width: ink.width, height: ink.height)
    }
}

final class MessageMentionLayoutManager: NSLayoutManager {
    var revealedSpoilers: Set<Int> = [] {
        didSet {
            if revealedSpoilers != oldValue { resetSpoilerParticles() }
        }
    }
    var particlePhase: CGFloat = 0
    private var spoilerFields: [Int: MessageSpoilerParticleField] = [:]

    func resetSpoilerParticles() { spoilerFields.removeAll(keepingCapacity: true) }

    func isConcealed(at index: Int) -> Bool {
        guard let textStorage, index >= 0, index < textStorage.length,
            let ids = textStorage.attribute(.bubbleSpoiler, at: index, effectiveRange: nil)
                as? [Int]
        else { return false }
        return ids.contains { !revealedSpoilers.contains($0) }
    }

    var hasConcealedSpoilers: Bool {
        guard let textStorage, textStorage.length > 0 else { return false }
        var hidden = false
        textStorage.enumerateAttribute(
            .bubbleSpoiler, in: NSRange(location: 0, length: textStorage.length)
        ) { _, range, stop in
            if self.isConcealed(at: range.location) {
                hidden = true
                stop.pointee = true
            }
        }
        return hidden
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.bubbleSpoiler, in: characters) { _, range, _ in
            guard !self.isConcealed(at: range.location) else { return }
            let glyphs = NSIntersectionRange(
                glyphsToShow, self.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
            if glyphs.length > 0 { super.drawGlyphs(forGlyphRange: glyphs, at: origin) }
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        // Drawing backgrounds a run at a time also suppresses inline-code colors
        // and mention pills beneath a concealed spoiler.
        guard let storage = textStorage else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.bubbleSpoiler, in: characterRange) { _, range, _ in
            guard !self.isConcealed(at: range.location) else { return }
            let glyphs = NSIntersectionRange(
                glyphsToShow, self.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
            if glyphs.length > 0 { super.drawBackground(forGlyphRange: glyphs, at: origin) }
        }
        guard let textStorage, let container = textContainers.first else { return }
        let characters = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.bubbleMentionTint, in: characters) { value, range, _ in
            guard let color = value as? BubbleNativeColor, !self.isConcealed(at: range.location)
            else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                color.setFill()
                let background = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: 1)
                #if os(macOS)
                    NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
                #else
                    UIBezierPath(roundedRect: background, cornerRadius: 4).fill()
                #endif
            }
        }
        textStorage.enumerateAttribute(.bubbleSpoiler, in: characters) { _, range, _ in
            guard self.isConcealed(at: range.location) else { return }
            var fullRange = NSRange()
            _ = textStorage.attribute(
                .bubbleSpoiler, at: range.location,
                longestEffectiveRange: &fullRange,
                in: NSRange(location: 0, length: textStorage.length))
            let glyphs = self.glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
            var rectangles: [CGRect] = []
            self.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                let mask = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: 2)
                if mask.width > 0 && mask.height > 0 { rectangles.append(mask) }
            }
            let field: MessageSpoilerParticleField
            if let existing = self.spoilerFields[fullRange.location] {
                field = existing
            } else {
                field = MessageSpoilerParticleField()
                self.spoilerFields[fullRange.location] = field
            }
            let color =
                (textStorage.attribute(
                    .foregroundColor, at: fullRange.location,
                    effectiveRange: nil) as? BubbleNativeColor) ?? bubbleLabelColor
            field.draw(in: rectangles, color: color)
        }
    }
}

extension NSAttributedString.Key {
    static let bubbleURL = NSAttributedString.Key("ChahuaURL")
    static let bubbleBodyFont = NSAttributedString.Key("ChahuaBodyFont")
    static let bubbleMentionID = NSAttributedString.Key("ChahuaMentionID")
    static let bubbleMentionTint = NSAttributedString.Key("ChahuaMentionTint")
    static let bubbleSpoiler = NSAttributedString.Key("ChahuaSpoiler")
    static let bubbleCodeBlock = NSAttributedString.Key("ChahuaCodeBlock")
}
