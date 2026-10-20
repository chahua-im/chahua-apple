#if os(macOS)
    import AppKit
    import SwiftUI

    /// SwiftUI Text does not expose inline glyph rectangles for particle masks.
    /// Drawing the shared TextKit graph preserves masks while hit testing passes
    /// through to the parent button/row, rather than creating embedded link actions.
    final class MessageSummaryNativeView: NSView {
        let summaryLayout = MessageSummaryLayout()
        private let animator = MessageSpoilerAnimator()
        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            NotificationCenter.default.addObserver(
                self, selector: #selector(pauseAnimation),
                name: NSApplication.didResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(updateAnimation),
                name: NSApplication.didBecomeActiveNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(updateAnimation),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }

        required init?(coder: NSCoder) { nil }

        func configure(_ text: NSAttributedString, accessibilityText: String, lineLimit: Int = 1) {
            summaryLayout.update(text, lineLimit: lineLimit)
            setAccessibilityLabel(accessibilityText)
            updateAnimation()
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }

        func clear() {
            configure(NSAttributedString(string: ""), accessibilityText: "")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.clip(to: bounds)
            summaryLayout.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        override func layout() {
            super.layout()
            needsDisplay = true
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateAnimation()
        }

        @objc private func pauseAnimation() { animator.stop() }

        @objc private func updateAnimation() {
            guard window != nil, summaryLayout.hasSpoilers, NSApplication.shared.isActive,
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            else {
                animator.stop()
                return
            }
            animator.start { [weak self] in
                guard let self else { return }
                self.summaryLayout.manager.particlePhase += 1.0 / 24
                self.needsDisplay = true
            }
        }
    }

    struct MessageSummaryRepresentable: NSViewRepresentable {
        let attributedText: NSAttributedString
        let accessibilityText: String
        let lineLimit: Int

        func makeNSView(context: Context) -> MessageSummaryNativeView {
            MessageSummaryNativeView(frame: .zero)
        }

        func updateNSView(_ view: MessageSummaryNativeView, context: Context) {
            view.configure(
                attributedText, accessibilityText: accessibilityText, lineLimit: lineLimit)
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize, nsView: MessageSummaryNativeView, context: Context
        )
            -> CGSize?
        {
            nsView.summaryLayout.size(width: proposal.width ?? 1_000_000)
        }
    }
#endif
