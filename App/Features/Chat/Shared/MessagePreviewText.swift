import ChahuaAPI
import Foundation

func messagePreview(_ preview: MessagePreview) -> String {
    MessagePreviewRenderer.render(
        preview,
        labels: .init(
            attachment: String(localized: "[Attachment]"),
            deleted: String(localized: "[Deleted]"),
            image: String(localized: "[Image]"),
            invite: String(localized: "[Invite]"),
            sticker: String(localized: "[Sticker]"),
            video: String(localized: "[Video]"),
            voiceMessage: String(localized: "[Voice message]")
        )
    )
}
