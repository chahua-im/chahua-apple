import ChahuaAPI
import CoreGraphics

/// Source dimensions are display points, bounded by the surface without upscaling.
enum StickerMediaLayout {
    static func size(for media: MessageStickerMediaResponse?, fitting bounds: CGSize) -> CGSize {
        guard bounds.width.isFinite, bounds.height.isFinite,
            bounds.width > 0, bounds.height > 0
        else { return .zero }
        guard let media, let sourceWidth = media.width, let sourceHeight = media.height,
            sourceWidth > 0, sourceHeight > 0
        else {
            let side = min(bounds.width, bounds.height)
            return CGSize(width: side, height: side)
        }
        let width = CGFloat(sourceWidth)
        let height = CGFloat(sourceHeight)
        let scale = min(1, bounds.width / width, bounds.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}
