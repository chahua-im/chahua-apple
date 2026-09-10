import ChahuaAPI
import SwiftUI

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

struct BubbleTextContent {
    let text: String
    let mentions: [MentionInfo]
    let currentUserID: Int32?
    let isOutgoing: Bool
    let action: ((URL) -> Void)?
    var mentionAction: ((Int32) -> Void)? = nil
    var metadata: BubbleMetadata? = nil
    var failureAction: (() -> Void)? = nil
    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var fontSize = NSFont.preferredFont(forTextStyle: .body).pointSize
    #else
    @ScaledMetric(relativeTo: .body) private var fontSize = UIFont.preferredFont(
        forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    ).pointSize
    #endif

    func update(_ layout: BubbleTextLayout, coordinator: Coordinator) -> Bool {
        coordinator.openLink = action
        coordinator.openMention = mentionAction
        let input = TextInput(
            text: text, mentions: mentions, currentUserID: currentUserID,
            isOutgoing: isOutgoing, fontSize: fontSize,
            linksEnabled: action != nil, mentionsEnabled: mentionAction != nil
        )
        let attributed: NSAttributedString?
        if coordinator.textInput != input {
            attributed = Self.attributedText(
                text: text, mentions: mentions, currentUserID: currentUserID,
                isOutgoing: isOutgoing, font: .systemFont(ofSize: fontSize),
                linksEnabled: input.linksEnabled, mentionsEnabled: input.mentionsEnabled
            )
            coordinator.textInput = input
        } else {
            attributed = nil
        }
        return layout.update(attributedText: attributed, metadata: metadata)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // Width proposals and replacement callbacks do not change the selectable runs.
    // Keep this local to the native view's lifetime rather than caching message text globally.
    struct TextInput: Equatable {
        let text: String
        let mentions: [MentionInfo]
        let currentUserID: Int32?
        let isOutgoing: Bool
        let fontSize: CGFloat
        let linksEnabled: Bool
        let mentionsEnabled: Bool
    }

    final class Coordinator: NSObject {
        var openLink: ((URL) -> Void)?
        var openMention: ((Int32) -> Void)?
        var textInput: TextInput?

        func activateLink(in storage: NSAttributedString, at charIndex: Int) {
            guard charIndex >= 0, charIndex < storage.length,
                  storage.attribute(.link, at: charIndex, effectiveRange: nil) != nil else { return }
            if let uid = storage.attribute(.bubbleMentionID, at: charIndex, effectiveRange: nil) as? NSNumber {
                openMention?(uid.int32Value)
            } else if let url = storage.attribute(.bubbleURL, at: charIndex, effectiveRange: nil) as? URL {
                openLink?(url)
            }
        }
    }

    private static let mentionPattern = try! NSRegularExpression(pattern: #"@\[uid:(\d+)\]"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"https?://[A-Za-z0-9\-._~:/?#@!$&'()*+,;=%]+"#)

    static func expandingMentions(in text: String, mentions: [MentionInfo]) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        var names: [Int32: String] = [:]
        for mention in mentions {
            if let name = mention.username, !name.isEmpty { names[mention.uid] = name }
        }
        for match in mentionPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let rawID = source.substring(with: match.range(at: 1))
            let name = Int32(rawID).flatMap { names[$0] } ?? "User \(rawID)"
            result.replaceCharacters(in: match.range, with: "@\(name)")
        }
        return result as String
    }

    static func attributedText(
        text: String, mentions: [MentionInfo], currentUserID: Int32?, isOutgoing: Bool,
        font: BubbleNativeFont = .preferredFont(forTextStyle: .body),
        linksEnabled: Bool = false, mentionsEnabled: Bool = false
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(font.pointSize * 1.4)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let foreground: BubbleNativeColor = isOutgoing ? .white : bubbleLabelColor
        let base: [NSAttributedString.Key: Any] = [.font: font, .bubbleBodyFont: font, .foregroundColor: foreground, .paragraphStyle: paragraph]
        let output = NSMutableAttributedString(string: "")
        let source = text as NSString
        var names: [Int32: String] = [:]
        for mention in mentions {
            if let name = mention.username, !name.isEmpty { names[mention.uid] = name }
        }

        func appendText(_ text: String) {
            let run = NSMutableAttributedString(string: text, attributes: base)
            let string = text as NSString
            for match in linkPattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                var range = match.range
                while range.length > 0, ".,);!?".contains(string.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))) {
                    range.length -= 1
                }
                guard range.length > 0, let url = URL(string: string.substring(with: range)) else { continue }
                run.addAttributes([.bubbleURL: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
                if linksEnabled { run.addAttribute(.link, value: url, range: range) }
            }
            output.append(run)
        }

        var offset = 0
        for match in mentionPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            appendText(source.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            let rawID = source.substring(with: match.range(at: 1))
            guard let uid = Int32(rawID) else {
                appendText(source.substring(with: match.range))
                offset = NSMaxRange(match.range)
                continue
            }
            let mentionFont = BubbleNativeFont.systemFont(ofSize: font.pointSize * 0.9, weight: .semibold)
            let isSelf = uid == currentUserID
            let tint: BubbleNativeColor = isOutgoing ? .white : .systemBlue
            // En spaces with an 8pt font reserve exactly four points at either edge.
            // They remain part of the selectable run rather than separate wrapping views.
            let run = NSMutableAttributedString(string: "\u{2002}@\(names[uid] ?? "User \(uid)")\u{2002}", attributes: base)
            let range = NSRange(location: 0, length: run.length)
            run.addAttributes([
                .font: mentionFont, .foregroundColor: tint,
                .bubbleMentionID: NSNumber(value: uid), .bubbleMentionTint: tint.withAlphaComponent(isSelf ? 0.28 : 0.14)
            ], range: range)
            for location in [0, run.length - 1] {
                run.addAttribute(.font, value: BubbleNativeFont.systemFont(ofSize: 8), range: NSRange(location: location, length: 1))
            }
            if mentionsEnabled, let target = URL(string: "chahua-mention://\(uid)") {
                run.addAttribute(.link, value: target, range: range)
            }
            output.append(run)
            offset = NSMaxRange(match.range)
        }
        appendText(source.substring(from: offset))
        return output
    }
}

struct BubbleMetadata {
    let time: String
    let state: ConversationMessageDisplayState?
    let size: CGSize
    private let attributedTime: NSAttributedString
    private let textSize: CGSize
    private let symbolSize: CGFloat
    let symbol: BubbleNativeImage?
    private let textOpacity: CGFloat

    init(time: String, state: ConversationMessageDisplayState?, isOutgoing: Bool, isOverlay: Bool = false, fontSize: CGFloat = 12) {
        self.time = time
        self.state = state
        textOpacity = isOverlay ? 1 : 0.7
        symbolSize = fontSize
        let foreground: BubbleNativeColor = isOutgoing || isOverlay ? .white : bubbleLabelColor
        let text = NSAttributedString(string: time, attributes: [
            .font: BubbleNativeFont.systemFont(ofSize: fontSize),
            .foregroundColor: foreground
        ])
        attributedTime = text
        textSize = text.size()
        size = CGSize(width: ceil(textSize.width) + (state == nil ? 0 : 4 + fontSize), height: ceil(max(textSize.height, fontSize)))
        if let state {
            let name: String
            switch state {
            case .queued, .sending: name = "checkmark.circle"
            case .delivered: name = "checkmark.circle.fill"
            case .failed: name = "exclamationmark.circle.fill"
            }
            let color = state == .failed ? BubbleNativeColor.systemRed : foreground.withAlphaComponent(isOverlay ? 1 : 0.7)
            #if os(macOS)
            let configuration = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
                .applying(.init(paletteColors: [color]))
            symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            #else
            let configuration = UIImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
                .applying(UIImage.SymbolConfiguration(paletteColors: [color]))
            symbol = UIImage(systemName: name, withConfiguration: configuration)
            #endif
        } else {
            symbol = nil
        }
    }

    init(row: TimelineMessageRow, isOverlay: Bool = false, fontSize: CGFloat = 12) {
        let time = row.entry.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: Locale.current.identifier + "@hours=h23")))
            + (row.entry.remoteMessage?.isEdited == true ? " " + String(localized: "(Edited)") : "")
        self.init(time: time, state: row.isOutgoing ? row.entry.displayState : nil,
                  isOutgoing: row.isOutgoing, isOverlay: isOverlay, fontSize: fontSize)
    }

    var accessibilityLabel: String {
        guard let state else { return time }
        let label: String
        switch state {
        case .queued: label = String(localized: "Queued")
        case .sending: label = String(localized: "Sending")
        case .delivered: label = String(localized: "Sent")
        case .failed: label = String(localized: "Failed to send")
        }
        return "\(time), \(label)"
    }

    func symbolFrame(in frame: CGRect) -> CGRect {
        guard symbol != nil, frame.width > 0, size.width > 0 else { return .zero }
        let scale = min(1, frame.width / size.width)
        return CGRect(
            x: frame.minX + (size.width - symbolSize) * scale,
            y: frame.minY + (size.height - symbolSize) / 2 * scale,
            width: symbolSize * scale,
            height: symbolSize * scale
        )
    }

    func draw(in frame: CGRect, drawsSymbol: Bool = true) {
        guard frame.width > 0, size.width > 0 else { return }
        #if os(macOS)
        let context = NSGraphicsContext.current?.cgContext
        #else
        let context = UIGraphicsGetCurrentContext()
        #endif
        guard let context else { return }
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.minY)
        let scale = min(1, frame.width / size.width)
        context.scaleBy(x: scale, y: scale)
        context.setAlpha(textOpacity)
        attributedTime.draw(at: CGPoint(x: 0, y: (size.height - textSize.height) / 2))
        context.restoreGState()
        if drawsSymbol {
            #if os(macOS)
            symbol?.draw(in: symbolFrame(in: frame), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            #else
            symbol?.draw(in: symbolFrame(in: frame))
            #endif
        }
    }
}

struct BubbleTextGeometry {
    let size: CGSize
    let bodyBounds: CGRect
    let lastLineBounds: CGRect
    let metadataFrame: CGRect
    let metadataIsInline: Bool
}

/// TextKit is the single source of line breaks and height for both the table measurer
/// and the selectable on-screen text view. Metadata is drawn outside the text storage.
final class BubbleTextLayout {
    let storage = NSTextStorage()
    let layoutManager = BubbleMentionLayoutManager()
    let textContainer = NSTextContainer(size: .zero)
    private(set) var metadata: BubbleMetadata?
    private var cachedGeometry: BubbleTextGeometry?
    private var cachedIdealSize: CGSize?

    init(attributedText: NSAttributedString = NSAttributedString(string: ""), metadata: BubbleMetadata? = nil) {
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        update(attributedText: attributedText, metadata: metadata)
    }

    @discardableResult
    func update(attributedText: NSAttributedString? = nil, metadata: BubbleMetadata?) -> Bool {
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

    func geometry(for proposedWidth: CGFloat) -> BubbleTextGeometry {
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
        let result = BubbleTextGeometry(
            size: CGSize(width: width, height: ceil(max(bodyBounds.maxY, metadataFrame.maxY))),
            bodyBounds: bodyBounds, lastLineBounds: lastLine,
            metadataFrame: metadataFrame, metadataIsInline: inline
        )
        cachedGeometry = result
        return result
    }
}


final class BubbleMentionLayoutManager: NSLayoutManager {
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

private extension NSAttributedString.Key {
    static let bubbleURL = NSAttributedString.Key("ChahuaURL")
    static let bubbleBodyFont = NSAttributedString.Key("ChahuaBodyFont")
    static let bubbleMentionID = NSAttributedString.Key("ChahuaMentionID")
    static let bubbleMentionTint = NSAttributedString.Key("ChahuaMentionTint")
}

private var bubbleLabelColor: BubbleNativeColor {
    #if os(macOS)
    .labelColor
    #else
    .label
    #endif
}

func messagePreview(_ preview: MessagePreview) -> String {
    switch preview.messageType {
    case .invite: return String(localized: "[Invite]")
    case .sticker:
        let emoji = preview.sticker?.emoji ?? ""
        return String(localized: "[Sticker]") + (emoji.isEmpty ? "" : " \(emoji)")
    case .audio: return String(localized: "[Voice message]")
    case .file: return String(localized: "[Attachment]")
    default:
        let prefix = preview.attachments.map { attachment in
            if attachment.kind.hasPrefix("image/") { return String(localized: "[Image]") }
            if attachment.kind.hasPrefix("video/") { return String(localized: "[Video]") }
            if attachment.kind.hasPrefix("audio/") { return String(localized: "[Voice message]") }
            return String(localized: "[Attachment]")
        }.joined()
        let original = preview.message ?? ""
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return prefix }
        let rendered = BubbleTextContent.expandingMentions(in: original, mentions: preview.mentions)
        return prefix.isEmpty ? rendered : "\(prefix) \(rendered)"
    }
}
