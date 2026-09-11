import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MessageTextGeometry {
    let size: CGSize
    let bodyBounds: CGRect
    let lastLineBounds: CGRect
    let metadataFrame: CGRect
    let metadataIsInline: Bool
}

/// TextKit is the single source of line breaks and height for both the table measurer
/// and the selectable on-screen text view. Metadata is drawn outside the text storage.
final class MessageTextLayout {
    let storage = NSTextStorage()
    let layoutManager = MessageMentionLayoutManager()
    let textContainer = NSTextContainer(size: .zero)
    private(set) var metadata: MessageMetadata?
    private var cachedGeometry: MessageTextGeometry?
    private var cachedIdealSize: CGSize?

    init(attributedText: NSAttributedString = NSAttributedString(string: ""), metadata: MessageMetadata? = nil) {
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

    private var metadataGap: CGFloat {
        let font = storage.length > 0 ? storage.attribute(.bubbleBodyFont, at: 0, effectiveRange: nil) as? BubbleNativeFont ?? storage.attribute(.font, at: 0, effectiveRange: nil) as? BubbleNativeFont : nil
        return ("0" as NSString).size(withAttributes: [.font: font ?? BubbleNativeFont.preferredFont(forTextStyle: .body)]).width * 1.5
    }

    var idealSize: CGSize {
        if let cachedIdealSize { return cachedIdealSize }
        let geometry = geometry(for: 1_000_000)
        let width = max(geometry.bodyBounds.maxX, geometry.lastLineBounds.maxX + (storage.length > 0 && metadata != nil ? metadataGap : 0) + (metadata?.size.width ?? 0))
        let size = self.geometry(for: max(1, ceil(width))).size
        cachedIdealSize = size
        return size
    }

    func fittingSize(width: CGFloat?) -> CGSize {
        geometry(for: width ?? idealSize.width).size
    }

    func geometry(for proposedWidth: CGFloat) -> MessageTextGeometry {
        let width = proposedWidth.isFinite ? max(1, proposedWidth) : 1_000_000
        if let cachedGeometry, cachedGeometry.size.width == width { return cachedGeometry }
        textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        var bodyBounds = storage.length == 0 ? CGRect.zero : layoutManager.usedRect(for: textContainer)
        var lastLine = CGRect.zero
        let glyphs = layoutManager.glyphRange(for: textContainer)
        // Native text views may extend used line fragments to the container edge
        // for selection. Those rectangles are not the intrinsic glyph width.
        let text = storage.string as NSString
        var maximumGlyphX: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
            var inkRange = range
            while inkRange.length > 0 {
                let character = text.character(at: self.layoutManager.characterIndexForGlyph(at: NSMaxRange(inkRange) - 1))
                guard character == 10 || character == 13 || character == 0x2028 || character == 0x2029 else { break }
                inkRange.length -= 1
            }
            let ink = inkRange.length > 0 ? self.layoutManager.boundingRect(forGlyphRange: inkRange, in: self.textContainer) : .zero
            maximumGlyphX = max(maximumGlyphX, ink.maxX)
            lastLine = CGRect(x: used.minX, y: used.minY, width: max(0, ink.maxX - used.minX), height: used.height)
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
        let metadataSize = CGSize(width: naturalMetadata.width * scale, height: naturalMetadata.height * scale)
        let inline = metadata != nil && storage.length > 0 && lastLine.maxX + metadataGap + metadataSize.width <= width
        let metadataY = inline ? max(lastLine.minY, lastLine.maxY - metadataSize.height) : ceil(bodyBounds.maxY)
        let metadataFrame = metadata == nil ? CGRect.zero : CGRect(x: width - metadataSize.width, y: metadataY, width: metadataSize.width, height: metadataSize.height)
        let result = MessageTextGeometry(
            size: CGSize(width: width, height: ceil(max(bodyBounds.maxY, metadataFrame.maxY))),
            bodyBounds: bodyBounds, lastLineBounds: lastLine,
            metadataFrame: metadataFrame, metadataIsInline: inline
        )
        cachedGeometry = result
        return result
    }
}


final class MessageMentionLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.bubbleMentionTint, in: characters) { value, range, _ in
            guard let color = value as? BubbleNativeColor else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                color.setFill()
                let background = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: 1)
                #if os(macOS)
                NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
                #else
                UIBezierPath(roundedRect: background, cornerRadius: 4).fill()
                #endif
            }
        }
    }
}

extension NSAttributedString.Key {
    static let bubbleURL = NSAttributedString.Key("ChahuaURL")
    static let bubbleBodyFont = NSAttributedString.Key("ChahuaBodyFont")
    static let bubbleMentionID = NSAttributedString.Key("ChahuaMentionID")
    static let bubbleMentionTint = NSAttributedString.Key("ChahuaMentionTint")
}
