import ChahuaAPI
import Foundation

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
        let rendered = MessageMentions.expanding(in: original, mentions: preview.mentions)
        return prefix.isEmpty ? rendered : "\(prefix) \(rendered)"
    }
}
