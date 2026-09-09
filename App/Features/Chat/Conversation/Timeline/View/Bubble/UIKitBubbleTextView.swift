#if os(iOS)
import SwiftUI
import UIKit

extension BubbleTextContent: UIViewRepresentable {
    func makeUIView(context: Context) -> UIKitBubbleTextView {
        let view = UIKitBubbleTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UIKitBubbleTextView, context: Context) {
        let selection = view.selectedRange
        let geometryChanged = update(view.contentLayout, coordinator: context.coordinator)
        if view.selectedRange != selection, selection.location != NSNotFound {
            let location = min(selection.location, view.textStorage.length)
            view.selectedRange = NSRange(location: location, length: min(selection.length, view.textStorage.length - location))
        }
        view.failureAction = failureAction
        if geometryChanged {
            view.setNeedsLayout()
            view.invalidateIntrinsicContentSize()
        }
        view.setNeedsDisplay()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIKitBubbleTextView, context: Context) -> CGSize? {
        uiView.contentLayout.fittingSize(width: proposal.width)
    }
}

extension BubbleTextContent.Coordinator: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction {
            activateLink(in: textView.textStorage, at: characterRange.location)
        }
        // UIKit's URL previews and menus must not bypass the current app actions.
        return false
    }

    @available(iOS 17.0, *)
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        UIAction { [weak self, weak textView] _ in
            guard let textView else { return }
            self?.activateLink(in: textView.textStorage, at: textItem.range.location)
        }
    }

    @available(iOS 17.0, *)
    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        nil
    }
}

final class UIKitBubbleTextView: UITextView {
    let contentLayout: BubbleTextLayout
    var failureAction: (() -> Void)? {
        didSet { updateFailureButton() }
    }
    private var failureButton: BubbleFailureButton?
    private var laidOutWidth: CGFloat?

    init() {
        let layout = BubbleTextLayout()
        contentLayout = layout
        // Supplying the shared TextKit 1 container keeps sizing and visible glyphs
        // on the same layout manager rather than UITextView's TextKit 2 default.
        super.init(frame: .zero, textContainer: layout.textContainer)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        isOpaque = false
        textContainerInset = .zero
        contentInset = .zero
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        delaysContentTouches = false
        dataDetectorTypes = []
        linkTextAttributes = [:]
        layout.textContainer.widthTracksTextView = false
        layout.textContainer.heightTracksTextView = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        contentLayout.fittingSize(width: bounds.width > 0 ? bounds.width : nil)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        contentLayout.fittingSize(width: size.width)
    }

    override func layoutSubviews() {
        let geometry = contentLayout.geometry(for: bounds.width)
        super.layoutSubviews()
        if laidOutWidth != bounds.width {
            laidOutWidth = bounds.width
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
        if let failureButton, let metadata = contentLayout.metadata {
            failureButton.frame = metadata.symbolFrame(in: geometry.metadataFrame)
            bringSubviewToFront(failureButton)
        }
    }

    override func draw(_ rect: CGRect) {
        let geometry = contentLayout.geometry(for: bounds.width)
        super.draw(rect)
        contentLayout.metadata?.draw(in: geometry.metadataFrame, drawsSymbol: failureButton == nil)
    }

    override var accessibilityValue: String? {
        get {
            guard let metadata = contentLayout.metadata else { return super.accessibilityValue }
            return "\(text ?? "") \(metadata.accessibilityLabel)"
        }
        set { super.accessibilityValue = newValue }
    }

    private func updateFailureButton() {
        guard failureAction != nil, let metadata = contentLayout.metadata, metadata.state == .failed else {
            failureButton?.removeFromSuperview()
            failureButton = nil
            accessibilityCustomActions = nil
            return
        }
        let button: BubbleFailureButton
        if let failureButton {
            button = failureButton
        } else {
            button = BubbleFailureButton(frame: .zero)
            button.imageView?.contentMode = .scaleAspectFit
            button.addTarget(self, action: #selector(openFailureOptions), for: .touchUpInside)
            button.accessibilityLabel = String(localized: "Failed to send. Retry options")
            addSubview(button)
            failureButton = button
            // Keep UITextView's native selectable-text accessibility element and
            // expose retry on it, without replacing it with a custom container.
            accessibilityCustomActions = [UIAccessibilityCustomAction(
                name: String(localized: "Failed to send. Retry options"),
                target: self, selector: #selector(performAccessibleFailureAction)
            )]
        }
        button.setImage(metadata.symbol, for: .normal)
        setNeedsLayout()
    }

    @objc private func openFailureOptions() {
        guard contentLayout.metadata?.state == .failed else { return }
        failureAction?()
    }

    @objc private func performAccessibleFailureAction() -> Bool {
        guard contentLayout.metadata?.state == .failed, let failureAction else { return false }
        failureAction()
        return true
    }
}

private final class BubbleFailureButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -max(0, (44 - bounds.width) / 2), dy: -max(0, (44 - bounds.height) / 2)).contains(point)
    }
}
#endif
