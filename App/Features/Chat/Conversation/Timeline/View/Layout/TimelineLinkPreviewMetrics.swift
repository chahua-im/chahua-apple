import ChahuaAPI
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

    /// This graph is retained in the row cache and consumed directly by both native hosts.
    static func layout(
        _ preview: MessageLinkPreview, cardWidth: CGFloat, bodySize: CGFloat,
        captionSize: CGFloat, rightToLeft: Bool
    ) -> LinkPreviewFlowLayout? {
        guard preview.status == .ready else { return nil }
        let domain = URL(string: preview.url)?.host ?? preview.url
        let title = preview.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(macOS)
            let titleSize = bodySize * 0.875
        #else
            let titleSize = bodySize * 14 / 17
        #endif
        return LinkPreviewFlowLayout(
            title: title?.isEmpty == false ? title! : domain,
            description: preview.description, domain: domain, width: max(1, cardWidth - 20),
            titleFont: .systemFont(ofSize: titleSize, weight: .semibold),
            descriptionFont: .systemFont(ofSize: descriptionFontSize(bodySize: bodySize)),
            domainFont: .systemFont(ofSize: captionSize),
            thumbnailSize: thumbnailSize(bodySize: bodySize), rightToLeft: rightToLeft,
            descriptionLineLimit: descriptionLineLimit)
    }

    static func thumbnailSize(bodySize: CGFloat) -> CGFloat {
        36 * max(1, bodySize / 17)
    }

    /// Keep the pre-existing pending skeleton extent; image completion never affects it.
    static func pendingHeight(bodySize: CGFloat, captionSize: CGFloat) -> CGFloat {
        max(
            thumbnailSize(bodySize: bodySize),
            ceil(bodySize * 0.875 * 1.2 + captionSize * 1.2 + 2)) + 12
    }
}
