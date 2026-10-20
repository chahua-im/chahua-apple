import ChahuaAPI
import ChahuaMarkdown
import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

struct MessageTextContent {
    let text: String
    let mentions: [MentionInfo]
    let currentUserID: Int32?
    let isOutgoing: Bool
    let action: ((URL) -> Void)?
    var mentionAction: ((Int32) -> Void)? = nil
    var metadata: MessageMetadata? = nil
    var failureAction: (() -> Void)? = nil
    let geometry: MessageTextGeometry
    let fontSize: CGFloat
    var document: MarkdownDocument? = nil

    func update(_ layout: MessageTextLayout, coordinator: Coordinator) -> Bool {
        coordinator.openLink = action
        coordinator.openMention = mentionAction
        coordinator.layout = layout
        let input = TextInput(
            text: text, mentions: mentions, currentUserID: currentUserID,
            isOutgoing: isOutgoing, fontSize: fontSize,
            linksEnabled: action != nil, mentionsEnabled: mentionAction != nil)
        let attributed: NSAttributedString?
        if coordinator.textInput != input {
            if coordinator.textInput?.text != text {
                coordinator.document = document ?? MarkdownDocument(parsing: text)
                layout.layoutManager.revealedSpoilers.removeAll()
            }
            attributed = Self.attributedText(
                document: coordinator.document ?? MarkdownDocument(parsing: text),
                mentions: mentions, currentUserID: currentUserID,
                isOutgoing: isOutgoing, font: .systemFont(ofSize: fontSize),
                linksEnabled: input.linksEnabled, mentionsEnabled: input.mentionsEnabled)
            coordinator.textInput = input
        } else {
            attributed = nil
        }
        let textGeometryChanged = layout.update(attributedText: attributed, metadata: metadata)
        let assignedGeometryChanged = layout.install(geometry: geometry)
        return textGeometryChanged || assignedGeometryChanged
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        var document: MarkdownDocument?
        weak var layout: MessageTextLayout?
        var spoilerChanged: (() -> Void)?
        var previousSelection = NSRange(location: 0, length: 0)

        @discardableResult
        func toggleSpoiler(at index: Int, onlyIfHidden: Bool = false) -> Bool {
            guard let layout, index >= 0, index < layout.storage.length,
                let ids = layout.storage.attribute(.bubbleSpoiler, at: index, effectiveRange: nil)
                    as? [Int]
            else { return false }
            let manager = layout.layoutManager
            if let hidden = ids.first(where: { !manager.revealedSpoilers.contains($0) }) {
                manager.revealedSpoilers.formUnion(ids.prefix(through: ids.firstIndex(of: hidden)!))
            } else {
                guard !onlyIfHidden, let id = ids.last else { return false }
                manager.revealedSpoilers.remove(id)
            }
            manager.invalidateDisplay(
                forCharacterRange: NSRange(location: 0, length: layout.storage.length))
            spoilerChanged?()
            return true
        }

        func activateLink(in storage: NSAttributedString, at charIndex: Int) {
            // A concealed link's first activation reveals its spoiler, never navigates.
            if toggleSpoiler(at: charIndex, onlyIfHidden: true) { return }
            guard charIndex >= 0, charIndex < storage.length,
                storage.attribute(.link, at: charIndex, effectiveRange: nil) != nil
            else { return }
            if let uid = storage.attribute(.bubbleMentionID, at: charIndex, effectiveRange: nil)
                as? NSNumber
            {
                openMention?(uid.int32Value)
            } else if let url = storage.attribute(.bubbleURL, at: charIndex, effectiveRange: nil)
                as? URL
            {
                openLink?(url)
            }
        }
    }

    static func attributedText(
        text: String, mentions: [MentionInfo], currentUserID: Int32?, isOutgoing: Bool,
        font: BubbleNativeFont = .preferredFont(forTextStyle: .body),
        linksEnabled: Bool = false, mentionsEnabled: Bool = false
    ) -> NSAttributedString {
        attributedText(
            document: MarkdownDocument(parsing: text), mentions: mentions,
            currentUserID: currentUserID, isOutgoing: isOutgoing, font: font,
            linksEnabled: linksEnabled, mentionsEnabled: mentionsEnabled)
    }

    static func attributedText(
        document: MarkdownDocument, mentions: [MentionInfo], currentUserID: Int32?,
        isOutgoing: Bool,
        font: BubbleNativeFont, linksEnabled: Bool = false, mentionsEnabled: Bool = false
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(font.pointSize * 1.4)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let foreground: BubbleNativeColor = isOutgoing ? .white : bubbleLabelColor
        let base: [NSAttributedString.Key: Any] = [
            .font: font, .bubbleBodyFont: font, .foregroundColor: foreground,
            .paragraphStyle: paragraph,
        ]
        let output = NSMutableAttributedString(string: "")
        let names = MessageMentions.names(in: mentions)
        var spoilerID = 0

        func append(_ value: String, _ attributes: [NSAttributedString.Key: Any]) {
            output.append(NSAttributedString(string: value, attributes: attributes))
        }
        func inline(_ nodes: [MarkdownInline], _ attributes: [NSAttributedString.Key: Any]) {
            for node in nodes {
                var attributes = attributes
                switch node {
                case .text(let value): append(value, attributes)
                case .strong(let children):
                    attributes[.font] = MessageMarkdownStyle.font(
                        attributes[.font] as? BubbleNativeFont ?? font, bold: true)
                    inline(children, attributes)
                case .emphasis(let children):
                    attributes[.font] = MessageMarkdownStyle.font(
                        attributes[.font] as? BubbleNativeFont ?? font, italic: true)
                    inline(children, attributes)
                case .strikethrough(let children):
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    inline(children, attributes)
                case .spoiler(let children):
                    spoilerID += 1
                    attributes[.bubbleSpoiler] =
                        (attributes[.bubbleSpoiler] as? [Int] ?? []) + [spoilerID]
                    #if os(macOS)
                        attributes[.cursor] = NSCursor.pointingHand
                    #endif
                    inline(children, attributes)
                case .code(let value):
                    attributes[.font] = BubbleNativeFont.monospacedSystemFont(
                        ofSize: font.pointSize * 0.92, weight: .regular)
                    attributes[.backgroundColor] = MessageMarkdownStyle.codeBackground
                    attributes[.foregroundColor] = MessageMarkdownStyle.codeForeground
                    append(value, attributes)
                case .link(let destination, let children):
                    if let url = URL(string: destination),
                        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                    {
                        attributes[.bubbleURL] = url
                        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                        if linksEnabled { attributes[.link] = url }
                    }
                    inline(children, attributes)
                case .mention(let uid):
                    attributes[.font] = BubbleNativeFont.systemFont(
                        ofSize: font.pointSize * 0.9, weight: .semibold)
                    let tint: BubbleNativeColor = isOutgoing ? .white : .systemBlue
                    attributes[.foregroundColor] = tint
                    attributes[.bubbleMentionID] = NSNumber(value: uid)
                    attributes[.bubbleMentionTint] = tint.withAlphaComponent(
                        uid == currentUserID ? 0.28 : 0.14)
                    if mentionsEnabled {
                        attributes[.link] = URL(string: "chahua-mention://\(uid)")
                    }
                    let start = output.length
                    append("\u{2002}@\(names[uid] ?? "User \(uid)")\u{2002}", attributes)
                    for location in [start, output.length - 1] {
                        output.addAttribute(
                            .font, value: BubbleNativeFont.systemFont(ofSize: 8),
                            range: NSRange(location: location, length: 1))
                    }
                }
            }
        }
        func blocks(_ nodes: [MarkdownBlock], depth: Int = 0, prefix: String? = nil) {
            for (index, node) in nodes.enumerated() {
                if index > 0 { append("\n", base) }
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                style.headIndent = CGFloat(depth) * font.pointSize * 1.3
                style.firstLineHeadIndent = style.headIndent
                if index == 0, let prefix {
                    style.firstLineHeadIndent = CGFloat(max(0, depth - 1)) * font.pointSize * 1.3
                    style.headIndent =
                        style.firstLineHeadIndent
                        + (prefix as NSString).size(withAttributes: [.font: font]).width
                }
                var attributes = base
                attributes[.paragraphStyle] = style
                switch node {
                case .paragraph(let children):
                    if index == 0, let prefix { append(prefix, attributes) }
                    inline(children, attributes)
                case .codeBlock(let language, let code):
                    if index == 0, let prefix {
                        append(prefix + "\n", attributes)
                        style.firstLineHeadIndent = style.headIndent
                    }
                    let attachment = MessageCodeAttachment(
                        code: code, language: language, fontSize: font.pointSize)
                    attributes[.attachment] = attachment
                    attributes[.bubbleCodeBlock] = attachment
                    // Attachment height is its own measured no-wrap TextKit height.
                    style.minimumLineHeight = 0
                    style.maximumLineHeight = 0
                    append("\u{FFFC}", attributes)
                case .list(let orderedStart, let items):
                    for (itemIndex, item) in items.enumerated() {
                        if itemIndex > 0 { append("\n", base) }
                        let prefix = orderedStart.map { "\($0 + itemIndex). " } ?? "• "
                        blocks(item, depth: depth + 1, prefix: prefix)
                    }
                }
            }
        }
        blocks(document.blocks)
        return output
    }
}
