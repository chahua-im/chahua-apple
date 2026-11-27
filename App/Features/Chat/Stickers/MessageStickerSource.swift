import ChahuaAPI
import Foundation

extension MessageResponse {
    /// Mirrors the server's published-message sticker conversion constraints.
    var canAddToStickerPack: Bool {
        messageType == .text && !isDeleted && forwardedFrom == nil
            && (message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && attachments.count == 1
            && attachments[0].kind.hasPrefix("image/")
            && attachments[0].size <= 10 * 1_024 * 1_024
    }
}
