import ChahuaAPI
import ChahuaMarkdown
import Foundation
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Plain summaries are reserved for navigation/window titles and accessibility.
/// Displayed previews use MessageSummaryText or MessageSummaryNativeView so styles
/// and the original spoiler geometry survive without enabling embedded actions.
func messagePreview(_ preview: MessagePreview) -> String {
    MessageSummaryContent.plain(MessageSummaryContent.summary(preview), mentions: preview.mentions)
}

enum MessageSummaryContent {
    private static var forwardedMessagesLabel: String {
        "[\(AppLanguage.localized("Forwarded Messages"))]"
    }

    static func placeholderLabel(_ reason: String?) -> String {
        switch reason {
        case "pendingAudio": AppLanguage.localized("[Pending voice message]")
        case "nestedForward": forwardedMessagesLabel
        default: AppLanguage.localized("[Unavailable message]")
        }
    }

    static func author(_ preview: MessagePreview) -> String {
        if let name = preview.forwardedFromName {
            return AppLanguage.localized("Forwarded from \(name)")
        }
        return preview.sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(preview.sender.uid)"
    }

    static func forwardedSummary(_ preview: ForwardedMessagePreviewResponse) -> String {
        let value = MessagePreview(
            id: preview.originalMessageId, clientGeneratedId: "",
            createdAt: preview.originalCreatedAt,
            sender: preview.sender, messageType: preview.messageType,
            attachments: preview.attachments,
            mentions: preview.mentions, message: preview.message, sticker: preview.sticker)
        return messagePreview(value)
    }
    private static let newlinePattern = try! NSRegularExpression(pattern: #"\R+"#)

    private static func names(in mentions: [MentionInfo]) -> [Int32: String] {
        MessageMentions.names(in: mentions).mapValues { name in
            newlinePattern.stringByReplacingMatches(
                in: name, range: NSRange(name.startIndex..., in: name), withTemplate: " ")
        }
    }

    private static var labels: MessagePreviewRenderer.Labels {
        .init(
            attachment: AppLanguage.localized("[Attachment]"),
            deleted: AppLanguage.localized("[Deleted]"),
            image: AppLanguage.localized("[Image]"),
            invite: AppLanguage.localized("[Invite]"),
            sticker: AppLanguage.localized("[Sticker]"),
            video: AppLanguage.localized("[Video]"),
            voiceMessage: AppLanguage.localized("[Voice message]"),
            forwarded: forwardedMessagesLabel,
            pendingAudio: AppLanguage.localized("[Pending voice message]"),
            nestedForward: forwardedMessagesLabel,
            unavailable: AppLanguage.localized("[Unavailable message]"))
    }

    static func summary(_ preview: MessagePreview) -> [MarkdownInline] {
        if preview.isDeleted { return [.text(labels.deleted)] }
        switch preview.messageType {
        case .invite, .sticker, .audio, .file, .forwarded, .placeholder:
            return [.text(MessagePreviewRenderer.render(preview, labels: labels))]
        default:
            // Keep attachment and system-message semantics identical to the API's
            // preview renderer, but parse only the source message, never labels or names.
            let prefix = preview.attachments.map { attachment in
                let mime =
                    attachment.kind.split(separator: ";", maxSplits: 1)
                    .first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                if mime.hasPrefix("image/") { return labels.image }
                if mime.hasPrefix("video/") { return labels.video }
                if mime.hasPrefix("audio/") { return labels.voiceMessage }
                return labels.attachment
            }.joined()
            guard let source = preview.message,
                !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return prefix.isEmpty ? [] : [.text(prefix)] }
            let nodes = MarkdownDocument(parsing: source).summary
            return prefix.isEmpty ? nodes : [.text(prefix + " ")] + nodes
        }
    }

    static func plain(_ nodes: [MarkdownInline], mentions: [MentionInfo]) -> String {
        let names = names(in: mentions)
        func flatten(_ nodes: [MarkdownInline]) -> String {
            nodes.map { node in
                switch node {
                case .text(let text), .code(let text): return text
                case .strong(let children), .emphasis(let children), .strikethrough(let children),
                    .link(_, let children):
                    return flatten(children)
                case .spoiler: return "••••"
                case .mention(let uid): return "@\(names[uid] ?? "User \(uid)")"
                }
            }.joined()
        }
        return flatten(nodes)
    }

    static func attributedText(
        _ nodes: [MarkdownInline], mentions: [MentionInfo], font: BubbleNativeFont,
        color: BubbleNativeColor
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let names = names(in: mentions)
        var spoilerID = 0
        func render(_ nodes: [MarkdownInline], attributes: [NSAttributedString.Key: Any]) {
            for node in nodes {
                var attributes = attributes
                switch node {
                case .text(let text):
                    output.append(NSAttributedString(string: text, attributes: attributes))
                case .code(let text):
                    attributes[.font] = BubbleNativeFont.monospacedSystemFont(
                        ofSize: font.pointSize, weight: .regular)
                    attributes[.backgroundColor] = MessageMarkdownStyle.codeBackground
                    attributes[.foregroundColor] = MessageMarkdownStyle.codeForeground
                    output.append(NSAttributedString(string: text, attributes: attributes))
                case .strong(let children):
                    attributes[.font] = MessageMarkdownStyle.font(
                        attributes[.font] as? BubbleNativeFont ?? font, bold: true)
                    render(children, attributes: attributes)
                case .emphasis(let children):
                    attributes[.font] = MessageMarkdownStyle.font(
                        attributes[.font] as? BubbleNativeFont ?? font, italic: true)
                    render(children, attributes: attributes)
                case .strikethrough(let children):
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    render(children, attributes: attributes)
                case .spoiler(let children):
                    spoilerID += 1
                    attributes[.bubbleSpoiler] =
                        (attributes[.bubbleSpoiler] as? [Int] ?? []) + [spoilerID]
                    render(children, attributes: attributes)
                case .link(let destination, let children):
                    // Preserve link typography, never link/URL action attributes.
                    if let scheme = URL(string: destination)?.scheme?.lowercased(),
                        scheme == "http" || scheme == "https"
                    {
                        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    render(children, attributes: attributes)
                case .mention(let uid):
                    output.append(
                        NSAttributedString(
                            string: "@\(names[uid] ?? "User \(uid)")", attributes: attributes))
                }
            }
        }
        render(nodes, attributes: [.font: font, .foregroundColor: color])
        return output
    }
}

/// One inert TextKit graph provides matching measurement, truncation, and spoiler
/// particle rectangles to SwiftUI previews and the existing native quote controls.
final class MessageSummaryLayout {
    let storage = NSTextStorage()
    let manager = MessageMentionLayoutManager()
    let container = NSTextContainer(size: .zero)
    private(set) var hasSpoilers = false

    init() {
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byTruncatingTail
        container.maximumNumberOfLines = 1
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    func update(_ text: NSAttributedString, lineLimit: Int) {
        container.maximumNumberOfLines = lineLimit
        guard !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
        manager.revealedSpoilers.removeAll()
        manager.resetSpoilerParticles()
        hasSpoilers = false
        storage.enumerateAttribute(.bubbleSpoiler, in: NSRange(location: 0, length: storage.length))
        {
            value, _, stop in
            if value != nil {
                self.hasSpoilers = true
                stop.pointee = true
            }
        }
    }

    func size(width: CGFloat) -> CGSize {
        container.size = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let rect = manager.usedRect(for: container)
        return CGSize(width: min(width, ceil(rect.maxX)), height: ceil(rect.maxY))
    }

    func draw(in bounds: CGRect) {
        _ = size(width: bounds.width)
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: .zero)
        manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }
}

struct MessageSummaryText: View {
    let nodes: [MarkdownInline]
    let mentions: [MentionInfo]
    var fontSize: CGFloat
    var color: Color
    var weight: BubbleNativeFont.Weight
    var lineLimit: Int
    @ScaledMetric(relativeTo: .body) private var fontScale: CGFloat = 1

    init(
        _ preview: MessagePreview, fontSize: CGFloat = 15, color: Color = .primary,
        weight: BubbleNativeFont.Weight = .regular, lineLimit: Int = 1,
        prefix: String = "", boldPrefix: Bool = false, fallback: String = ""
    ) {
        let summary = MessageSummaryContent.summary(preview)
        nodes =
            (prefix.isEmpty ? [] : boldPrefix ? [.strong([.text(prefix)])] : [.text(prefix)])
            + (summary.isEmpty ? [.text(fallback)] : summary)
        mentions = preview.mentions
        self.fontSize = fontSize
        self.color = color
        self.weight = weight
        self.lineLimit = lineLimit
    }

    init(source: String, fontSize: CGFloat = 17, color: Color = .secondary, prefix: String = "") {
        nodes = (prefix.isEmpty ? [] : [.text(prefix)]) + MarkdownDocument(parsing: source).summary
        mentions = []
        self.fontSize = fontSize
        self.color = color
        weight = .regular
        lineLimit = 1
    }

    var body: some View {
        MessageSummaryRepresentable(
            attributedText: MessageSummaryContent.attributedText(
                nodes, mentions: mentions,
                font: .systemFont(ofSize: fontSize * fontScale, weight: weight),
                color: BubbleNativeColor(color)),
            accessibilityText: MessageSummaryContent.plain(nodes, mentions: mentions),
            lineLimit: lineLimit)
    }
}
