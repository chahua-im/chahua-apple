#if os(macOS)
import AppKit
import ChahuaAPI
import SwiftUI

struct MacBubbleTextContent: NSViewRepresentable {
    let text: String
    let mentions: [MentionInfo]
    let currentUserID: Int32?
    let isOutgoing: Bool
    let action: ((URL) -> Void)?
    var mentionAction: ((Int32) -> Void)? = nil
    var metadata: MacBubbleMetadata? = nil
    @ScaledMetric(relativeTo: .body) private var fontSize = NSFont.preferredFont(forTextStyle: .body).pointSize

    func makeNSView(context: Context) -> MacBubbleTextView {
        let view = MacBubbleTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MacBubbleTextView, context: Context) {
        context.coordinator.openLink = action
        context.coordinator.openMention = mentionAction
        let attributed = Self.attributedText(
            text: text, mentions: mentions, currentUserID: currentUserID,
            isOutgoing: isOutgoing, font: .systemFont(ofSize: fontSize),
            linksEnabled: action != nil, mentionsEnabled: mentionAction != nil
        )
        view.contentLayout.update(attributedText: attributed, metadata: metadata)
        view.needsDisplay = true
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacBubbleTextView, context: Context) -> CGSize? {
        let ideal = nsView.contentLayout.idealSize
        return nsView.contentLayout.geometry(for: min(ideal.width, proposal.width ?? ideal.width)).size
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openLink: ((URL) -> Void)?
        var openMention: ((Int32) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let storage = textView.textStorage, charIndex < storage.length else { return true }
            if let uid = storage.attribute(.macMentionID, at: charIndex, effectiveRange: nil) as? NSNumber {
                openMention?(uid.int32Value)
            } else if let url = storage.attribute(.macURL, at: charIndex, effectiveRange: nil) as? URL {
                openLink?(url)
            }
            // Never let AppKit open a URL itself, including when a handler was removed.
            return true
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
        font: NSFont = .preferredFont(forTextStyle: .body),
        linksEnabled: Bool = false, mentionsEnabled: Bool = false
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(font.pointSize * 1.4)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let foreground: NSColor = isOutgoing ? .white : .labelColor
        let base: [NSAttributedString.Key: Any] = [.font: font, .macBodyFont: font, .foregroundColor: foreground, .paragraphStyle: paragraph]
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
                run.addAttributes([.macURL: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
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
            let mentionFont = NSFont.systemFont(ofSize: font.pointSize * 0.9, weight: .semibold)
            let isSelf = uid == currentUserID
            let tint: NSColor = isOutgoing ? .white : .systemBlue
            // En spaces with an 8pt font reserve exactly four points at either edge.
            // They remain part of the selectable run rather than separate wrapping views.
            let run = NSMutableAttributedString(string: "\u{2002}@\(names[uid] ?? "User \(uid)")\u{2002}", attributes: base)
            let range = NSRange(location: 0, length: run.length)
            run.addAttributes([
                .font: mentionFont, .foregroundColor: isOutgoing ? NSColor.white : tint,
                .macMentionID: NSNumber(value: uid), .macMentionTint: tint.withAlphaComponent(isSelf ? 0.28 : 0.14)
            ], range: range)
            for location in [0, run.length - 1] {
                run.addAttribute(.font, value: NSFont.systemFont(ofSize: 8), range: NSRange(location: location, length: 1))
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

struct MacBubbleMetadata {
    let time: String
    let state: ConversationMessageDisplayState?
    let size: CGSize
    private let attributedTime: NSAttributedString
    private let textSize: CGSize
    private let symbolSize: CGFloat
    private let symbol: NSImage?
    private let textOpacity: CGFloat

    init(time: String, state: ConversationMessageDisplayState?, isOutgoing: Bool, isOverlay: Bool = false, fontSize: CGFloat = 12) {
        self.time = time
        self.state = state
        textOpacity = isOverlay ? 1 : 0.7
        symbolSize = fontSize
        let foreground: NSColor = isOutgoing || isOverlay ? .white : .labelColor
        let text = NSAttributedString(string: time, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
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
            case .failed: name = "exclamationmark.triangle.fill"
            }
            let color = state == .failed ? NSColor.systemYellow : foreground.withAlphaComponent(isOverlay ? 1 : 0.7)
            let configuration = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
                .applying(.init(paletteColors: [color]))
            symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
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

    func draw(in frame: CGRect) {
        guard frame.width > 0, size.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: frame.minX, yBy: frame.minY)
        transform.scale(by: min(1, frame.width / size.width))
        transform.concat()
        NSGraphicsContext.current?.cgContext.setAlpha(textOpacity)
        attributedTime.draw(at: CGPoint(x: 0, y: (size.height - textSize.height) / 2))
        NSGraphicsContext.current?.cgContext.setAlpha(1)
        symbol?.draw(in: CGRect(x: size.width - symbolSize, y: (size.height - symbolSize) / 2, width: symbolSize, height: symbolSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

struct MacBubbleTextGeometry {
    let size: CGSize
    let bodyBounds: CGRect
    let lastLineBounds: CGRect
    let metadataFrame: CGRect
    let metadataIsInline: Bool
}

/// TextKit is the single source of line breaks and height for both the table measurer
/// and the selectable on-screen text view. Metadata is drawn outside the text storage.
final class MacBubbleTextLayout {
    let storage = NSTextStorage()
    let layoutManager = MacMentionLayoutManager()
    let textContainer = NSTextContainer(size: .zero)
    private(set) var metadata: MacBubbleMetadata?
    private var cachedGeometry: MacBubbleTextGeometry?
    private var cachedIdealSize: CGSize?

    init(attributedText: NSAttributedString = NSAttributedString(string: ""), metadata: MacBubbleMetadata? = nil) {
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        update(attributedText: attributedText, metadata: metadata)
    }

    func update(attributedText: NSAttributedString, metadata: MacBubbleMetadata?) {
        let textChanged = !storage.isEqual(to: attributedText)
        if textChanged { storage.setAttributedString(attributedText) }
        if textChanged || self.metadata?.size != metadata?.size {
            cachedGeometry = nil
            cachedIdealSize = nil
        }
        self.metadata = metadata
    }

    private var metadataGap: CGFloat {
        let font = storage.length > 0 ? storage.attribute(.macBodyFont, at: 0, effectiveRange: nil) as? NSFont ?? storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        return ("0" as NSString).size(withAttributes: [.font: font ?? NSFont.preferredFont(forTextStyle: .body)]).width * 1.5
    }

    var idealSize: CGSize {
        if let cachedIdealSize { return cachedIdealSize }
        let geometry = geometry(for: 1_000_000)
        let width = max(geometry.bodyBounds.maxX, geometry.lastLineBounds.maxX + (storage.length > 0 && metadata != nil ? metadataGap : 0) + (metadata?.size.width ?? 0))
        let size = self.geometry(for: max(1, ceil(width))).size
        cachedIdealSize = size
        return size
    }

    func geometry(for proposedWidth: CGFloat) -> MacBubbleTextGeometry {
        let width = proposedWidth.isFinite ? max(1, proposedWidth) : 1_000_000
        if let cachedGeometry, cachedGeometry.size.width == width { return cachedGeometry }
        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        var bodyBounds = storage.length == 0 ? CGRect.zero : layoutManager.usedRect(for: textContainer)
        var lastLine = CGRect.zero
        let glyphs = layoutManager.glyphRange(for: textContainer)
        // NSTextView may extend used line fragments to the container edge for
        // selection. Those rectangles are not the intrinsic width of the glyphs.
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
        let result = MacBubbleTextGeometry(
            size: CGSize(width: width, height: ceil(max(bodyBounds.maxY, metadataFrame.maxY))),
            bodyBounds: bodyBounds, lastLineBounds: lastLine,
            metadataFrame: metadataFrame, metadataIsInline: inline
        )
        cachedGeometry = result
        return result
    }
}

final class MacBubbleTextView: NSTextView {
    let contentLayout: MacBubbleTextLayout

    init() {
        let layout = MacBubbleTextLayout()
        contentLayout = layout
        super.init(frame: .zero, textContainer: layout.textContainer)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = false
        layout.textContainer.widthTracksTextView = false
        layout.textContainer.heightTracksTextView = false
        linkTextAttributes = [:]
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { contentLayout.idealSize }

    override func layout() {
        super.layout()
        _ = contentLayout.geometry(for: bounds.width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let geometry = contentLayout.geometry(for: bounds.width)
        super.draw(dirtyRect)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            contentLayout.metadata?.draw(in: geometry.metadataFrame)
        }
    }

    override func accessibilityValue() -> String? {
        guard let metadata = contentLayout.metadata else { return super.accessibilityValue() }
        return "\(string) \(metadata.accessibilityLabel)"
    }
}

final class MacMentionLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.macMentionTint, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                color.setFill()
                NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

private extension NSAttributedString.Key {
    static let macURL = NSAttributedString.Key("ChahuaURL")
    static let macBodyFont = NSAttributedString.Key("ChahuaBodyFont")
    static let macMentionID = NSAttributedString.Key("ChahuaMentionID")
    static let macMentionTint = NSAttributedString.Key("ChahuaMentionTint")
}

func macMessagePreview(_ preview: MessagePreview) -> String {
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
        let rendered = MacBubbleTextContent.expandingMentions(in: original, mentions: preview.mentions)
        return prefix.isEmpty ? rendered : "\(prefix) \(rendered)"
    }
}
#endif
