import ChahuaAPI
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Display names stay literal; only server-supplied identifiers confer navigation.
struct TimelineSystemMessageContent: Hashable {
    enum Target: Hashable {
        case profile(Int32)
        case message(MessageID)
    }

    struct Link: Hashable {
        let range: NSRange
        let target: Target
    }

    let text: String
    let actorRange: NSRange
    let links: [Link]

    init(message: MessageResponse, body: String) {
        let actor = message.sender.name.flatMap { $0.isEmpty ? nil : $0 }
        let prefix = actor.map { $0 + " " } ?? ""
        var text = prefix + body
        let actorRange = NSRange(location: 0, length: (actor ?? "").utf16.count)
        var links: [Link] = []
        let bodyRange = NSRange(location: prefix.utf16.count, length: body.utf16.count)
        if !message.isDeleted, let targets = message.systemLinks,
            targets.uid != nil || targets.messageId != nil
        {
            if actorRange.length > 0 {
                links.append(.init(range: actorRange, target: .profile(message.sender.uid)))
            }
            if let uid = targets.uid {
                let range: NSRange?
                // Wording is used only to locate a display span, never to identify
                // an event or a person. Changed/unknown wording gets an explicit action.
                switch message.systemKind {
                case .memberAdded:
                    range = Self.targetRange(body, prefix: "added ", offset: bodyRange.location)
                case .memberRemoved:
                    range = Self.targetRange(body, prefix: "removed ", offset: bodyRange.location)
                case .friendRequestAccepted:
                    range = Self.targetRange(
                        body, prefix: "accepted ", suffix: "'s friend request",
                        offset: bodyRange.location)
                default:
                    range = nil
                }
                if let range {
                    links.append(.init(range: range, target: .profile(uid)))
                } else {
                    Self.appendAction(
                        AppLanguage.localized("View Profile"), target: .profile(uid),
                        text: &text, links: &links)
                }
            }
            if let id = targets.messageId {
                switch message.systemKind {
                case .messagePinned, .messageUnpinned, .threadMessagePinned, .threadMessageUnpinned:
                    if bodyRange.length > 0 {
                        links.append(.init(range: bodyRange, target: .message(id)))
                    } else {
                        Self.appendAction(
                            AppLanguage.localized("View Message"), target: .message(id),
                            text: &text, links: &links)
                    }
                default:
                    Self.appendAction(
                        AppLanguage.localized("View Message"), target: .message(id),
                        text: &text, links: &links)
                }
            }
        }
        self.text = text
        self.actorRange = actorRange
        self.links = links
    }

    private static func targetRange(
        _ body: String, prefix: String, suffix: String = "", offset: Int
    ) -> NSRange? {
        guard body.hasPrefix(prefix), body.hasSuffix(suffix) else { return nil }
        let length = body.utf16.count - prefix.utf16.count - suffix.utf16.count
        guard length > 0 else { return nil }
        return NSRange(location: offset + prefix.utf16.count, length: length)
    }

    private static func appendAction(
        _ label: String, target: Target, text: inout String, links: inout [Link]
    ) {
        text += " · "
        let range = NSRange(location: text.utf16.count, length: label.utf16.count)
        text += label
        links.append(.init(range: range, target: target))
    }

    func attributedText(color: BubbleNativeColor, linksEnabled: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: BubbleNativeFont.systemFont(ofSize: 13), .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
        if actorRange.length > 0 {
            result.addAttribute(
                .font, value: BubbleNativeFont.systemFont(ofSize: 13, weight: .semibold),
                range: actorRange)
        }
        if linksEnabled {
            for link in links {
                result.addAttributes(
                    [
                        .foregroundColor: BubbleNativeColor(ChahuaTheme.accent),
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ], range: link.range)
            }
        }
        return result
    }
}

extension TimelineBubbleActions {
    func canOpenSystemTargets(in context: TimelineRowContext) -> Bool {
        openSystemMessage != nil && !interactionContext.isReadOnly
            && !isSelectingMessages && !context.isInteractionPreview
    }

    func openSystemTarget(_ target: TimelineSystemMessageContent.Target) {
        switch target {
        case .profile(let uid): openMention?(uid)
        case .message(let id): openSystemMessage?(id)
        }
    }
}

extension MessageSummaryLayout {
    /// The same TextKit graph draws and hit-tests wrapped, centered system text.
    /// Native inline hit testing is needed because SwiftUI cannot consume the
    /// timeline's prepared glyph geometry without a second row layout.
    func systemTarget(
        at point: CGPoint, width: CGFloat, content: TimelineSystemMessageContent
    ) -> TimelineSystemMessageContent.Target? {
        _ = size(width: width)
        guard storage.length > 0 else { return nil }
        let index = manager.characterIndex(
            for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length,
            let link = content.links.first(where: { NSLocationInRange(index, $0.range) })
        else { return nil }
        let glyphs = manager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard manager.boundingRect(forGlyphRange: glyphs, in: container).contains(point)
        else { return nil }
        return link.target
    }
}
