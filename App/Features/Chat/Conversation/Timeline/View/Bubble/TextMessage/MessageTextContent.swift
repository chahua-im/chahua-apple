import ChahuaAPI
import SwiftUI

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
    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var fontSize = NSFont.preferredFont(forTextStyle: .body).pointSize
    #else
    @ScaledMetric(relativeTo: .body) private var fontSize = UIFont.preferredFont(
        forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    ).pointSize
    #endif

    func update(_ layout: MessageTextLayout, coordinator: Coordinator) -> Bool {
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

    private static let linkPattern = try! NSRegularExpression(pattern: #"https?://[A-Za-z0-9\-._~:/?#@!$&'()*+,;=%]+"#)

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
        let names = MessageMentions.names(in: mentions)

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
        for match in MessageMentions.pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
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
