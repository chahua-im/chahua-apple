#if os(macOS)
    import AppKit

    /// Timeline rows own native selection and cached geometry. Drawing the shared
    /// indicator directly avoids both per-row SwiftUI layout and offscreen hosting
    /// for static rasters; Core Animation owns only the visible sending spinner.
    @MainActor
    final class TimelineDeliveryStatusView: NSView {
        private var content: MessageDeliveryStatusContent?
        private var path: CGPath?
        private var symbol: MessageDeliveryStatusSymbol?
        private let spinner = MessageDeliveryStatusSpinner()
        private var spinnerColor: CGColor?
        private var requestedVisible = true
        private var drawnSize = CGSize.zero

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.addSublayer(spinner.layer)
            setAccessibilityElement(false)
            setAccessibilityHidden(true)
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ metadata: MessageMetadata?) {
            let next = metadata?.statusContent
            guard content != next else { return }
            content = next
            path = next?.makePath()
            symbol = next?.makeSymbol()
            spinner.configure(next, path: path)
            isHidden = next == nil
            needsDisplay = true
            updateSpinner()
        }

        func setVisible(_ visible: Bool) {
            guard requestedVisible != visible else { return }
            requestedVisible = visible
            updateSpinnerVisibility()
        }

        // The native timestamp/retry button retain selection and accessibility.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if drawnSize != bounds.size {
                drawnSize = bounds.size
                needsDisplay = true
            }
            layoutSpinner()
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let content, let context = NSGraphicsContext.current?.cgContext else { return }
            content.draw(in: bounds, context: context, path: path, symbol: symbol)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsDisplay = true
            updateSpinner()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            needsDisplay = true
            updateSpinner()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
            updateSpinner()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateSpinnerVisibility()
        }

        override func viewDidHide() {
            super.viewDidHide()
            updateSpinnerVisibility()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            updateSpinnerVisibility()
        }

        private func updateSpinnerVisibility() {
            spinner.setVisible(
                requestedVisible && window != nil && !isHiddenOrHasHiddenAncestor
                    && !visibleRect.isEmpty && (content?.fittedScale(in: bounds) ?? 0) > 0)
        }

        private func updateSpinner() {
            if content?.status == .sending {
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    spinnerColor = content?.foreground.cgColor
                }
            } else {
                spinnerColor = nil
            }
            layoutSpinner()
        }

        private func layoutSpinner() {
            spinner.layout(
                in: bounds, color: spinnerColor,
                displayScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
            updateSpinnerVisibility()
        }
    }
#endif
