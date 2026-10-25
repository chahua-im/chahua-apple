#if os(iOS)
    import UIKit

    /// AVKit pages already own native containment/hit testing. A small native overlay
    /// shares the ring layer with AppKit without adding a hosting controller per page.
    @MainActor
    final class VideoDownloadProgressView: UIView {
        private let ring = VideoDownloadProgressRing()
        private let label = UILabel()

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            layer.addSublayer(ring)
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            label.textAlignment = .center
            addSubview(label)
            isAccessibilityElement = true
            accessibilityLabel = AppLanguage.localized("Loading video")
            update(.indeterminate)
        }

        required init?(coder: NSCoder) { nil }

        func update(_ progress: VideoDownloadProgress) {
            ring.update(progress)
            label.text = progress.percentage.map { "\($0)%" }
            accessibilityValue = label.text
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            ring.frame = bounds
            ring.updatePath()
            label.frame = bounds
        }
    }
#endif
