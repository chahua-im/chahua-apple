#if os(macOS)
    import AppKit

    /// An AppKit avatar keeps image lifecycle under native row visibility rather than
    /// adding a SwiftUI host to every timeline row and reaction participant.
    @MainActor
    final class TimelineAvatarView: NSView {
        private let imageView = TimelineImageView(frame: .zero)
        private var name: String?
        private var diameter: CGFloat = 0
        private var initials: NSAttributedString?
        private var initialsLineHeight: CGFloat = 0
        private var visible = false
        private var showsFallback = true
        private var fallbackColor: CGColor?

        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            imageView.showsPlaceholderChrome = false
            addSubview(imageView)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
        }

        required init?(coder: NSCoder) { nil }

        func configure(
            url: URL?, name: String, userID: Int32?, diameter: CGFloat, displayScale: CGFloat,
            mediaContext: AppMediaContext?
        ) {
            if self.name != name || self.diameter != diameter {
                self.name = name
                self.diameter = diameter
                let font = NSFont.systemFont(ofSize: diameter * 0.36, weight: .semibold)
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byClipping
                initials = NSAttributedString(
                    string: String(name.prefix(2)).uppercased(),
                    attributes: [
                        .font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
                    ])
                initialsLineHeight = ceil(font.ascender - font.descender + font.leading)
                // Preserve AvatarView's deterministic name hash and palette; user ID
                // does not change the fallback when the same name appears in a pill.
                var hash: Int32 = 0
                for scalar in name.unicodeScalars {
                    hash = (hash &<< 5) &- hash &+ Int32(truncatingIfNeeded: scalar.value)
                }
                let hue = CGFloat((hash &* 137) % 360)
                fallbackColor =
                    NSColor(
                        calibratedHue: (hue < 0 ? hue + 360 : hue) / 360,
                        saturation: 0.55 / 0.775, brightness: 0.775, alpha: 1
                    ).cgColor
                layer?.backgroundColor = showsFallback ? fallbackColor : nil
                needsDisplay = true
            }
            setAccessibilityLabel(AppLanguage.localized("Avatar for \(name)"))
            let pixels = ceil(diameter * displayScale)
            imageView.onImageAvailabilityChanged = { [weak self] available in
                guard let self else { return }
                self.showsFallback = !available
                self.layer?.backgroundColor = available ? nil : self.fallbackColor
                self.needsDisplay = true
            }
            imageView.configure(
                url: url, contentMode: .fill, animates: false, showsBlurredBackdrop: false,
                thumbnailPixelSize: CGSize(width: pixels, height: pixels),
                mediaContext: mediaContext)
            imageView.setVisible(visible)
            needsLayout = true
        }

        func clear() {
            imageView.clear()
            name = nil
            diameter = 0
            initials = nil
            visible = false
            showsFallback = true
            fallbackColor = nil
            layer?.backgroundColor = nil
            setAccessibilityLabel(nil)
            needsDisplay = true
        }

        func setVisible(_ visible: Bool) {
            self.visible = visible
            imageView.setVisible(visible)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            layer?.cornerRadius = min(bounds.width, bounds.height) / 2
            imageView.frame = bounds
            imageView.setVisible(visible)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard showsFallback else { return }
            initials?.draw(
                in: CGRect(
                    x: 0, y: (bounds.height - initialsLineHeight) / 2,
                    width: bounds.width, height: initialsLineHeight))
        }
    }
#endif
