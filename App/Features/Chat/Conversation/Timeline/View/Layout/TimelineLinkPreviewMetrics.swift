import CoreGraphics
import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Native cards consume these measured extents; image loading never changes row geometry.
enum TimelineLinkPreviewMetrics {
    static let descriptionLineLimit = 3

    static func descriptionFontSize(bodySize: CGFloat) -> CGFloat {
        bodySize * 13 / 17
    }

    /// Measure once with the row, not when native cards scroll or images arrive.
    static func descriptionHeight(
        _ text: String?, cardWidth: CGFloat, bodySize: CGFloat
    ) -> CGFloat {
        guard let text, text.contains(where: { !$0.isWhitespace }) else { return 0 }
        let width = max(0, cardWidth - thumbnailSize(bodySize: bodySize) - 29)
        guard width > 0 else { return 0 }
        let font = BubbleNativeFont.systemFont(ofSize: descriptionFontSize(bodySize: bodySize))
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let maximumHeight = lineHeight * CGFloat(descriptionLineLimit)
        let measured = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: width, height: maximumHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(min(maximumHeight, measured.height))
    }

    static func thumbnailSize(bodySize: CGFloat) -> CGFloat {
        36 * max(1, bodySize / 17)
    }

    static func height(
        bodySize: CGFloat, captionSize: CGFloat, descriptionHeight: CGFloat = 0
    ) -> CGFloat {
        let compact =
            max(
                thumbnailSize(bodySize: bodySize),
                ceil(bodySize * 0.875 * 1.2 + captionSize * 1.2 + 2)) + 12
        return compact + (descriptionHeight > 0 ? descriptionHeight + 4 : 0)
    }
}
