import ChahuaAPI
import SwiftUI

struct StickerShopStickerSlot: View {
    let media: MessageStickerMediaResponse
    let emoji: String
    var insetsArtwork = true

    var body: some View {
        // The square sets layout independently of the native media's intrinsic size.
        // Native media owns the inset unless the surrounding strip supplies it.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                StickerMediaView(media: media, emoji: emoji, insetsArtwork: insetsArtwork)
            }
    }
}
