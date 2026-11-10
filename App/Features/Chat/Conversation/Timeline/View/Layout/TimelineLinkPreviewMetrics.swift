import CoreGraphics

/// Native cards consume these measured extents; image loading never changes row geometry.
enum TimelineLinkPreviewMetrics {
    static func thumbnailSize(bodySize: CGFloat) -> CGFloat {
        36 * max(1, bodySize / 17)
    }

    static func height(bodySize: CGFloat, captionSize: CGFloat) -> CGFloat {
        max(thumbnailSize(bodySize: bodySize), ceil(bodySize * 0.875 * 1.2 + captionSize * 1.2 + 2))
            + 12
    }
}
