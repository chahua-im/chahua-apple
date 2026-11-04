#if os(iOS)
    import UIKit

    /// Native timeline sections retain TextKit geometry, selection, retry hit
    /// testing and accessibility. Shared Core Graphics paths and native SF Symbols
    /// avoid a SwiftUI content graph; only visible sending indicators animate.
    @MainActor
    final class TimelineDeliveryStatusView: UIView {
        private var content: MessageDeliveryStatusContent?
        private var path: CGPath?
        private var symbol: MessageDeliveryStatusSymbol?
        private let spinner = MessageDeliveryStatusSpinner()
        private var spinnerColor: CGColor?
        private var requestedVisible = true

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            contentMode = .redraw
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            layer.addSublayer(spinner.layer)
            registerForTraitChanges([
                UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                UITraitUserInterfaceLevel.self, UITraitDisplayGamut.self, UITraitDisplayScale.self,
            ]) { (view: TimelineDeliveryStatusView, _: UITraitCollection) in
                view.setNeedsDisplay()
                view.updateSpinner()
            }
        }

        required init?(coder: NSCoder) { nil }

        func configure(_ metadata: MessageMetadata?) {
            let next = metadata?.statusContent
            guard next != content else { return }
            content = next
            path = next?.makePath()
            symbol = next?.makeSymbol()
            spinner.configure(next, path: path)
            setNeedsDisplay()
            updateSpinner()
        }

        func clear() {
            configure(nil)
        }

        func setVisible(_ visible: Bool) {
            guard requestedVisible != visible else { return }
            requestedVisible = visible
            updateSpinnerVisibility()
        }

        override var isHidden: Bool {
            didSet {
                guard isHidden != oldValue else { return }
                updateSpinnerVisibility()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateSpinner()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            updateSpinnerVisibility()
        }

        override func draw(_ rect: CGRect) {
            guard let content, let context = UIGraphicsGetCurrentContext() else { return }
            content.draw(in: bounds, context: context, path: path, symbol: symbol)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutSpinner()
        }

        private func updateSpinnerVisibility() {
            var ancestor: UIView? = self
            var hidden = false
            while let view = ancestor {
                if view.isHidden || view.alpha == 0 {
                    hidden = true
                    break
                }
                ancestor = view.superview
            }
            let inViewport =
                window.map { !convert(bounds, to: $0).intersection($0.bounds).isEmpty }
                ?? false
            spinner.setVisible(
                requestedVisible && !hidden && inViewport
                    && (content?.fittedScale(in: bounds) ?? 0) > 0)
        }

        private func updateSpinner() {
            spinnerColor =
                content?.status == .sending
                ? content?.foreground.resolvedColor(with: traitCollection).cgColor : nil
            layoutSpinner()
        }

        private func layoutSpinner() {
            spinner.layout(
                in: bounds, color: spinnerColor,
                displayScale: traitCollection.displayScale)
            updateSpinnerVisibility()
        }
    }
#endif
