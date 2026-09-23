import Foundation

public enum MessagePreviewRenderer {
    public struct Labels: Sendable {
        public let attachment: String
        public let deleted: String
        public let image: String
        public let invite: String
        public let sticker: String
        public let video: String
        public let voiceMessage: String

        public init(
            attachment: String,
            deleted: String,
            image: String,
            invite: String,
            sticker: String,
            video: String,
            voiceMessage: String
        ) {
            self.attachment = attachment
            self.deleted = deleted
            self.image = image
            self.invite = invite
            self.sticker = sticker
            self.video = video
            self.voiceMessage = voiceMessage
        }
    }

    public static func render(_ preview: MessagePreview, labels: Labels) -> String {
        if preview.isDeleted { return labels.deleted }

        switch preview.messageType {
        case .invite:
            return labels.invite
        case .sticker:
            guard let emoji = preview.sticker?.emoji, !emoji.isEmpty else { return labels.sticker }
            return "\(labels.sticker) \(emoji)"
        case .audio:
            return labels.voiceMessage
        case .file:
            return labels.attachment
        default:
            var prefix = ""
            for attachment in preview.attachments {
                prefix += label(for: attachment.kind, labels: labels)
            }

            guard let message = preview.message,
                !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return prefix }

            let renderedMessage = singleLine(
                expandingMentions(in: message, mentions: preview.mentions))
            return prefix.isEmpty ? renderedMessage : "\(prefix) \(renderedMessage)"
        }
    }

    private static let mentionPattern = try! NSRegularExpression(pattern: #"@\[uid:(\d+)\]"#)
    private static let newlinePattern = try! NSRegularExpression(pattern: #"\R+"#)

    private static func singleLine(_ text: String) -> String {
        guard text.rangeOfCharacter(from: .newlines) != nil else { return text }
        return newlinePattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    private static func label(for kind: String, labels: Labels) -> String {
        let mimeType = kind.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if mimeType.hasPrefix("image/") { return labels.image }
        if mimeType.hasPrefix("video/") { return labels.video }
        if mimeType.hasPrefix("audio/") { return labels.voiceMessage }
        return labels.attachment
    }

    private static func expandingMentions(in text: String, mentions: [MentionInfo]) -> String {
        let source = text as NSString
        let matches = mentionPattern.matches(
            in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        var names: [Int32: String] = [:]
        for mention in mentions {
            if let name = mention.username, !name.isEmpty { names[mention.uid] = name }
        }

        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let rawID = source.substring(with: match.range(at: 1))
            let name = Int32(rawID).flatMap { names[$0] } ?? "User \(rawID)"
            result.replaceCharacters(in: match.range, with: "@\(name)")
        }
        return result as String
    }
}
