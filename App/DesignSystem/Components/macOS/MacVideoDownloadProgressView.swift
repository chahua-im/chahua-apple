#if os(macOS)
    import AppKit

    /// The existing AVPlayerView page needs a non-hit-testing native overlay. Share
    /// the ring layer with UIKit rather than adding a separate SwiftUI host per page.
    @MainActor
    final class VideoDownloadProgressView: NSView {
        private let ring = VideoDownloadProgressRing()
        private let label = NSTextField(labelWithString: "")

        override var isFlipped: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(ring)
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            label.alignment = .center
            addSubview(label)
            setAccessibilityElement(true)
            setAccessibilityRole(.progressIndicator)
            setAccessibilityLabel(AppLanguage.localized("Loading video"))
            update(.indeterminate)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(_ progress: VideoDownloadProgress) {
            ring.update(progress)
            label.stringValue = progress.percentage.map { "\($0)%" } ?? ""
            setAccessibilityValue(label.stringValue)
        }

        override func layout() {
            super.layout()
            ring.frame = bounds
            ring.updatePath()
            label.frame = CGRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
        }
    }
#endif
