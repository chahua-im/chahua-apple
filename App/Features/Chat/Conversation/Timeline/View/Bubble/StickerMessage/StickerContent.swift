import ChahuaAPI
import SwiftUI

struct StickerContent: View {
    @Environment(\.displayScale) private var displayScale
    let sticker: MessageStickerResponse?
    let size: CGSize

    var body: some View {
        Group {
            if let sticker, sticker.media.contentType.hasPrefix("image/") {
                RemoteImageView(
                    url: URL(string: sticker.media.url),
                    contentMode: .fit,
                    animates: RemoteImageFormat.isAnimated(contentType: sticker.media.contentType),
                    thumbnailPixelSize: CGSize(
                        width: size.width * displayScale,
                        height: size.height * displayScale
                    )
                )
            } else {
                VStack(spacing: 4) {
                    if let emoji = sticker?.emoji, !emoji.isEmpty { Text(emoji).font(.largeTitle) }
                    Label("Sticker preview unavailable", systemImage: "photo.badge.exclamationmark")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(8)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(sticker?.name ?? sticker?.emoji ?? String(localized: "[Sticker]"))
    }
}
