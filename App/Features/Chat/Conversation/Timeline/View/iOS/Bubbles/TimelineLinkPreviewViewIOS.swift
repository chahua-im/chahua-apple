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
        private let textView = LinkPreviewFlowTextView(frame: .zero)
        private let titleSkeleton = UIView()
        private let domainSkeleton = UIView()
        private var thumbnailSize: CGFloat = 36
        private var domainLineHeight: CGFloat = 0
        private var pending = false
        private var rightToLeft = false
        private var visible = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            layer.cornerRadius = 4
            isAccessibilityElement = true
            let decorations: [UIView] = [
                stripe, initial, image, textView,
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
            titleSkeleton.layer.cornerRadius = 4
            domainSkeleton.layer.cornerRadius = 4
            addSubview(marker)
            addTarget(self, action: #selector(activate), for: .touchUpInside)
        }

        required init?(coder: NSCoder) { nil }

        func configure(
            _ preview: MessageLinkPreview, outgoing: Bool, flowLayout: LinkPreviewFlowLayout?,
            environment: TimelineLayoutEnvironment, mediaContext: AppMediaContext?, enabled: Bool
        ) {
            pending = preview.status == .pending
            rightToLeft = environment.layoutDirection == .rightToLeft
            thumbnailSize = TimelineLinkPreviewMetrics.thumbnailSize(bodySize: environment.bodySize)
            let titleSize = environment.bodySize * 14 / 17
            textView.flowLayout = flowLayout
            initial.font = .systemFont(ofSize: titleSize, weight: .semibold)
            domainLineHeight = UIFont.systemFont(ofSize: environment.captionSize).lineHeight
            let domain = URL(string: preview.url)?.host ?? preview.url
            let title = preview.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let headline = title?.isEmpty == false ? title : domain
            backgroundColor =
                outgoing
                ? UIColor.black.withAlphaComponent(0.10)
                : UIColor.systemBlue.withAlphaComponent(0.08)
            stripe.backgroundColor = outgoing ? UIColor.white.withAlphaComponent(0.5) : .systemBlue
            textView.foregroundColor = outgoing ? .white : .label
            textView.secondaryColor =
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
            textView.isHidden = pending
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
                : [headline, preview.description, domain].compactMap { $0 }.joined(
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
            textView.flowLayout = nil
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
            textView.frame = CGRect(
                x: 10, y: 6, width: max(0, bounds.width - 20),
                height: textView.flowLayout?.height ?? 0)
            let thumbnailFrame =
                textView.flowLayout?.thumbnailFrame.offsetBy(dx: 10, dy: 6)
                ?? CGRect(
                    x: rightToLeft ? bounds.width - thumbnailSize - 10 : 10,
                    y: (bounds.height - thumbnailSize) / 2,
                    width: thumbnailSize, height: thumbnailSize)
            initial.frame = thumbnailFrame
            image.frame = thumbnailFrame
            let textX: CGFloat = rightToLeft ? 10 : thumbnailFrame.maxX + 9
            let textWidth = max(0, bounds.width - thumbnailSize - 29)
            let titleHeight = initial.font.lineHeight
            let domainHeight = domainLineHeight
            let top = (bounds.height - titleHeight - domainHeight - 1) / 2
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
