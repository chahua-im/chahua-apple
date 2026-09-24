#if os(iOS)
    import UIKit

    /// A UIKit avatar keeps image work under the measured row's visibility and reuse
    /// lifecycle; a SwiftUI host for each row/reactor would recreate the layout and
    /// AttributeGraph overhead this native timeline is intended to remove.
    @MainActor
    final class TimelineAvatarView: UIView {
        private let imageView = TimelineImageView(frame: .zero)
        private let initialsLabel = UILabel(frame: .zero)
        private var name: String?
        private var diameter: CGFloat = 0
        private var visible = false
        private var showsFallback = true
        private var fallbackColor: UIColor?

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityTraits = .image
            initialsLabel.textAlignment = .center
            initialsLabel.lineBreakMode = .byClipping
            initialsLabel.textColor = .white
            initialsLabel.isAccessibilityElement = false
            addSubview(initialsLabel)
            imageView.showsPlaceholderChrome = false
            addSubview(imageView)
        }

        required init?(coder: NSCoder) { nil }

        func configure(
            url: URL?, name: String, userID: Int32?, diameter: CGFloat, displayScale: CGFloat,
            mediaContext: AppMediaContext?
        ) {
            if self.name != name || self.diameter != diameter {
                self.name = name
                self.diameter = diameter
                initialsLabel.font = .systemFont(ofSize: diameter * 0.36, weight: .semibold)
                initialsLabel.text = String(name.prefix(2)).uppercased()
                // Match AvatarView's deterministic name palette (not the user ID).
                var hash: Int32 = 0
                for scalar in name.unicodeScalars {
                    hash = (hash &<< 5) &- hash &+ Int32(truncatingIfNeeded: scalar.value)
                }
                let hue = CGFloat((hash &* 137) % 360)
                fallbackColor = UIColor(
                    hue: (hue < 0 ? hue + 360 : hue) / 360,
                    saturation: 0.55 / 0.775, brightness: 0.775, alpha: 1)
                backgroundColor = showsFallback ? fallbackColor : .clear
            }
            accessibilityLabel = AppLanguage.localized("Avatar for \(name)")
            imageView.onImageAvailabilityChanged = { [weak self] available in
                guard let self else { return }
                self.showsFallback = !available
                self.initialsLabel.isHidden = available
                self.backgroundColor = available ? .clear : self.fallbackColor
            }
            let pixels = ceil(diameter * displayScale)
            imageView.configure(
                url: url, contentMode: .fill, animates: false, showsBlurredBackdrop: false,
                thumbnailPixelSize: CGSize(width: pixels, height: pixels),
                mediaContext: mediaContext)
            imageView.setVisible(visible)
            setNeedsLayout()
        }

        func clear() {
            imageView.clear()
            name = nil
            diameter = 0
            initialsLabel.text = nil
            initialsLabel.isHidden = false
            visible = false
            showsFallback = true
            fallbackColor = nil
            backgroundColor = .clear
            accessibilityLabel = nil
        }

        func setVisible(_ visible: Bool) {
            self.visible = visible
            imageView.setVisible(visible)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
            initialsLabel.frame = bounds
            imageView.frame = bounds
            imageView.setVisible(visible)
        }
    }
#endif
