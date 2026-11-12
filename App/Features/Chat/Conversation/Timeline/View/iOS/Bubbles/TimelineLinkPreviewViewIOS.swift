#if os(iOS)
    import ChahuaAPI
    import SwiftUI
    import UIKit

    /// The measured native bubble must retain its cached row geometry during scrolling
    /// and menu previews. A SwiftUI subtree would introduce independent layout work;
    /// this control only arranges pixels inside the engine-assigned card rectangle.
    @MainActor
    final class TimelineLinkPreviewView: UIControl {
        var onActivate: (() -> Void)?
        private let marker = MessageRowGestureMarker(frame: .zero)
        private let stripe = UIView()
        private let initial = UILabel()
        private let image = TimelineImageView(frame: .zero)
        private let titleLabel = UILabel()
        private let descriptionLabel = UILabel()
        private let domainLabel = UILabel()
        private let titleSkeleton = UIView()
        private let domainSkeleton = UIView()
        private var thumbnailSize: CGFloat = 36
        private var descriptionHeight: CGFloat = 0
        private var pending = false
        private var rightToLeft = false
        private var visible = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            layer.cornerRadius = 4
            isAccessibilityElement = true
            let decorations: [UIView] = [
                stripe, initial, image, titleLabel, descriptionLabel, domainLabel,
                titleSkeleton, domainSkeleton,
            ]
            for view in decorations {
                view.isUserInteractionEnabled = false
                view.isAccessibilityElement = false
                addSubview(view)
            }
            initial.textAlignment = .center
            initial.textColor = .white
            initial.layer.cornerRadius = 4
            initial.clipsToBounds = true
            image.layer.cornerRadius = 4
            image.showsPlaceholderChrome = false
            for label in [titleLabel, domainLabel] {
                label.numberOfLines = 1
                label.lineBreakMode = .byTruncatingTail
            }
            descriptionLabel.numberOfLines = TimelineLinkPreviewMetrics.descriptionLineLimit
            descriptionLabel.lineBreakMode = .byTruncatingTail
            descriptionLabel.isHidden = true
            titleSkeleton.layer.cornerRadius = 4
            domainSkeleton.layer.cornerRadius = 4
            addSubview(marker)
            addTarget(self, action: #selector(activate), for: .touchUpInside)
        }

        required init?(coder: NSCoder) { nil }

        func configure(
            _ preview: MessageLinkPreview, outgoing: Bool, descriptionHeight: CGFloat,
            environment: TimelineLayoutEnvironment, mediaContext: AppMediaContext?, enabled: Bool
        ) {
            pending = preview.status == .pending
            self.descriptionHeight = pending ? 0 : descriptionHeight
            rightToLeft = environment.layoutDirection == .rightToLeft
            thumbnailSize = TimelineLinkPreviewMetrics.thumbnailSize(bodySize: environment.bodySize)
            let titleSize = environment.bodySize * 14 / 17
            titleLabel.font = .systemFont(ofSize: titleSize, weight: .semibold)
            descriptionLabel.font = .systemFont(
                ofSize: TimelineLinkPreviewMetrics.descriptionFontSize(
                    bodySize: environment.bodySize))
            domainLabel.font = .systemFont(ofSize: environment.captionSize)
            initial.font = .systemFont(ofSize: titleSize, weight: .semibold)
            let domain = URL(string: preview.url)?.host ?? preview.url
            let title = preview.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            titleLabel.text = title?.isEmpty == false ? title : domain
            domainLabel.text = domain
            descriptionLabel.text = self.descriptionHeight > 0 ? preview.description : nil
            descriptionLabel.isHidden = self.descriptionHeight <= 0
            titleLabel.textAlignment = rightToLeft ? .right : .left
            domainLabel.textAlignment = titleLabel.textAlignment
            descriptionLabel.textAlignment = titleLabel.textAlignment
            backgroundColor =
                outgoing
                ? UIColor.black.withAlphaComponent(0.10)
                : UIColor.systemBlue.withAlphaComponent(0.08)
            stripe.backgroundColor = outgoing ? UIColor.white.withAlphaComponent(0.5) : .systemBlue
            titleLabel.textColor = outgoing ? .white : .label
            descriptionLabel.textColor = outgoing ? .white : .label
            domainLabel.textColor =
                outgoing ? UIColor.white.withAlphaComponent(0.85) : .secondaryLabel
            let skeletonColor =
                outgoing
                ? UIColor.white.withAlphaComponent(0.18)
                : UIColor.secondaryLabel.withAlphaComponent(0.15)
            initial.backgroundColor = pending ? skeletonColor : .systemOrange
            titleSkeleton.backgroundColor = skeletonColor
            domainSkeleton.backgroundColor = skeletonColor
            titleSkeleton.isHidden = !pending
            domainSkeleton.isHidden = !pending
            titleLabel.isHidden = pending
            domainLabel.isHidden = pending
            initial.text = pending ? nil : String(domain.prefix(1)).uppercased()
            image.isHidden = pending
            if !pending, let imageURL = preview.image?.url, let url = URL(string: imageURL) {
                image.onImageAvailabilityChanged = { [weak self] available in
                    self?.initial.isHidden = available
                }
                image.configure(
                    url: url, contentMode: .fill, animates: false, showsBlurredBackdrop: false,
                    thumbnailPixelSize: CGSize(
                        width: thumbnailSize * environment.displayScale,
                        height: thumbnailSize * environment.displayScale),
                    mediaContext: mediaContext)
            } else {
                image.clear()
                image.isHidden = true
                initial.isHidden = false
            }
            isEnabled = enabled && preview.status == .ready
            accessibilityTraits = isEnabled ? .link : .staticText
            accessibilityLabel =
                pending
                ? String(localized: "Loading link preview")
                : [titleLabel.text, descriptionLabel.text, domain].compactMap { $0 }.joined(
                    separator: ", ")
            accessibilityValue = pending ? nil : preview.url
            if isEnabled {
                marker.configure(.tap { [weak self] in self?.activate() })
            } else {
                marker.stop()
            }
            image.setVisible(visible && !image.isHidden)
            setNeedsLayout()
        }

        func setVisible(_ visible: Bool) {
            self.visible = visible
            image.setVisible(visible && !isHidden && !image.isHidden)
        }

        func refreshViewportVisibility() {
            image.setVisible(visible && !isHidden && !image.isHidden)
        }

        func clear() {
            visible = false
            image.clear()
            initial.isHidden = false
            descriptionHeight = 0
            descriptionLabel.text = nil
            descriptionLabel.isHidden = true
            descriptionLabel.frame = .zero
            onActivate = nil
            marker.stop()
            isEnabled = false
            accessibilityLabel = nil
            accessibilityValue = nil
            accessibilityCustomActions = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            marker.frame = bounds
            stripe.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
            let thumbnailX = rightToLeft ? bounds.width - thumbnailSize - 10 : 10
            let thumbnailFrame = CGRect(
                x: thumbnailX, y: descriptionHeight > 0 ? 6 : (bounds.height - thumbnailSize) / 2,
                width: thumbnailSize, height: thumbnailSize)
            initial.frame = thumbnailFrame
            image.frame = thumbnailFrame
            let textX: CGFloat = rightToLeft ? 10 : thumbnailFrame.maxX + 9
            let textWidth = max(0, bounds.width - thumbnailSize - 29)
            let titleHeight = titleLabel.font.lineHeight
            let domainHeight = domainLabel.font.lineHeight
            let top =
                descriptionHeight > 0
                ? 6 : (bounds.height - titleHeight - domainHeight - 1) / 2
            titleLabel.frame = CGRect(x: textX, y: top, width: textWidth, height: titleHeight)
            descriptionLabel.frame =
                descriptionHeight > 0
                ? CGRect(
                    x: textX, y: top + titleHeight + 2,
                    width: textWidth, height: descriptionHeight)
                : .zero
            domainLabel.frame = CGRect(
                x: textX,
                y: descriptionHeight > 0
                    ? top + titleHeight + descriptionHeight + 4 : top + titleHeight + 1,
                width: textWidth, height: domainHeight)
            titleSkeleton.frame = CGRect(
                x: textX, y: top + 2, width: textWidth * 0.78, height: max(8, titleHeight - 5))
            domainSkeleton.frame = CGRect(
                x: textX, y: top + titleHeight + 3, width: textWidth * 0.48,
                height: max(6, domainHeight - 5))
            refreshViewportVisibility()
        }

        @objc private func activate() {
            guard isEnabled else { return }
            onActivate?()
        }

        override func accessibilityActivate() -> Bool {
            guard isEnabled else { return false }
            activate()
            return true
        }
    }
#endif
