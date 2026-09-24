import ChahuaAPI
import Foundation

func messagePreview(_ preview: MessagePreview) -> String {
    MessagePreviewRenderer.render(
        preview,
        labels: .init(
            attachment: AppLanguage.localized("[Attachment]"),
            deleted: AppLanguage.localized("[Deleted]"),
            image: AppLanguage.localized("[Image]"),
            invite: AppLanguage.localized("[Invite]"),
            sticker: AppLanguage.localized("[Sticker]"),
            video: AppLanguage.localized("[Video]"),
            voiceMessage: AppLanguage.localized("[Voice message]")
        )
    )
}
