#if os(iOS)
    import UIKit

    /// Native labels consume the timeline engine's cached card rectangle, including menu previews.
    @MainActor
    final class TimelineForwardedCardView: UIControl {
        var onActivate: (() -> Void)?
        private var labels: [UILabel] = []
        private var lineCount = 0
        private let divider = UIView()
        private let marker = MessageRowGestureMarker(frame: .zero)
        private var cardLayout: TimelineForwardedCardLayout?

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(divider)
            addTarget(self, action: #selector(activate), for: .touchUpInside)
            isAccessibilityElement = true
            addSubview(marker)
        }
        required init?(coder: NSCoder) { nil }

        func configure(
            lines: [String], fontSize: CGFloat, footerFontSize: CGFloat,
            layout: TimelineForwardedCardLayout, outgoing: Bool, enabled: Bool
        ) {
            cardLayout = layout
            lineCount = lines.count
            while labels.count < lines.count {
                let label = UILabel()
                label.isUserInteractionEnabled = false
                label.lineBreakMode = .byTruncatingTail
                addSubview(label)
                labels.append(label)
            }
            for (index, label) in labels.enumerated() {
                label.isHidden = index >= lines.count
                guard index < lines.count else { continue }
                label.text = lines[index]
                label.font = .systemFont(
                    ofSize: index == lines.count - 1 && lines.count > 1 ? footerFontSize : fontSize,
                    weight: index == 0 ? .semibold : .regular)
                label.textColor =
                    outgoing
                    ? UIColor.white.withAlphaComponent(index == 0 ? 1 : 0.7)
                    : index == 0 ? .label : .secondaryLabel
            }
            divider.backgroundColor = outgoing ? UIColor.white.withAlphaComponent(0.2) : .separator
            isEnabled = enabled
            accessibilityLabel = lines.joined(separator: ", ")
            if enabled {
                marker.configure(.tap { [weak self] in self?.activate() })
            } else {
                marker.stop()
            }
            accessibilityTraits = enabled ? .button : .staticText
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let cardLayout else { return }
            marker.frame = bounds
            for (label, frame) in zip(labels.prefix(lineCount), cardLayout.labelFrames) {
                label.frame = frame
            }
            divider.frame = cardLayout.dividerFrame
        }
        @objc private func activate() { if isEnabled { onActivate?() } }
        override func accessibilityActivate() -> Bool {
            guard isEnabled else { return false }
            activate()
            return true
        }
    }
#endif
