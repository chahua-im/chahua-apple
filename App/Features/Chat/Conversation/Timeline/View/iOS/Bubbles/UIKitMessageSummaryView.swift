#if os(iOS)
    import SwiftUI
    import UIKit

    /// SwiftUI Text cannot expose inline glyph rectangles for particle masks. This
    /// noninteractive native drawing surface shares the body's TextKit masker and
    /// leaves every tap, context menu, and selection action with its parent row.
    final class MessageSummaryNativeView: UIView {
        let summaryLayout = MessageSummaryLayout()
        private let animator = MessageSpoilerAnimator()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            clipsToBounds = true
            isAccessibilityElement = true
            accessibilityTraits = .staticText
            NotificationCenter.default.addObserver(
                self, selector: #selector(pauseAnimation),
                name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(updateAnimation),
                name: UIApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(updateAnimation),
                name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        }

        required init?(coder: NSCoder) { nil }

        func configure(_ text: NSAttributedString, accessibilityText: String, lineLimit: Int = 1) {
            summaryLayout.update(text, lineLimit: lineLimit)
            accessibilityLabel = accessibilityText
            updateAnimation()
            setNeedsDisplay()
            invalidateIntrinsicContentSize()
        }

        func clear() {
            configure(NSAttributedString(string: ""), accessibilityText: "")
        }

        override func draw(_ rect: CGRect) { summaryLayout.draw(in: bounds) }
        override func layoutSubviews() {
            super.layoutSubviews()
            setNeedsDisplay()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateAnimation()
        }

        @objc private func pauseAnimation() { animator.stop() }

        @objc private func updateAnimation() {
            guard window != nil, summaryLayout.hasSpoilers,
                UIApplication.shared.applicationState == .active,
                !UIAccessibility.isReduceMotionEnabled
            else {
                animator.stop()
                return
            }
            animator.start { [weak self] in
                guard let self else { return }
                self.summaryLayout.manager.particlePhase += 1.0 / 24
                self.setNeedsDisplay()
            }
        }
    }

    struct MessageSummaryRepresentable: UIViewRepresentable {
        let attributedText: NSAttributedString
        let accessibilityText: String
        let lineLimit: Int

        func makeUIView(context: Context) -> MessageSummaryNativeView {
            MessageSummaryNativeView(frame: .zero)
        }

        func updateUIView(_ view: MessageSummaryNativeView, context: Context) {
            view.configure(
                attributedText, accessibilityText: accessibilityText, lineLimit: lineLimit)
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize, uiView: MessageSummaryNativeView, context: Context
        )
            -> CGSize?
        {
            uiView.summaryLayout.size(width: proposal.width ?? 1_000_000)
        }
    }
#endif
