import ChahuaAPI
import ChahuaMediaCache
import SwiftUI

struct StickerContent: View {
    let sticker: MessageStickerResponse?
    let viewport: CGSize
    let availableWidth: CGFloat
    let isMeasuring: Bool

    private var size: CGSize {
        let width = min(200, max(1, availableWidth))
        let ratio: CGFloat
        if let w = sticker?.media.width, let h = sticker?.media.height, w > 0, h > 0 {
            ratio = CGFloat(w) / CGFloat(h)
        } else {
            ratio = 1
        }
        return CGSize(width: width, height: min(width / ratio, max(1, viewport.height * 0.2)))
    }

    var body: some View {
        Group {
            if isMeasuring {
                Color.clear
            } else if let sticker, sticker.media.contentType.hasPrefix("image/") {
                RemoteImageView(
                    url: URL(string: sticker.media.url), contentMode: .fit,
                    animates: true, tag: CacheTag(rawValue: "chatMedia")
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
