#if os(macOS)
import AppKit
import SwiftUI

extension BubbleTextContent: NSViewRepresentable {
    func makeNSView(context: Context) -> AppKitBubbleTextView {
        let view = AppKitBubbleTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: AppKitBubbleTextView, context: Context) {
        let geometryChanged = update(view.contentLayout, coordinator: context.coordinator)
        view.failureAction = failureAction
        if geometryChanged {
            view.needsLayout = true
            view.invalidateIntrinsicContentSize()
        }
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppKitBubbleTextView, context: Context) -> CGSize? {
        nsView.contentLayout.fittingSize(width: proposal.width)
    }
}

extension BubbleTextContent.Coordinator: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let storage = textView.textStorage { activateLink(in: storage, at: charIndex) }
        // Never let AppKit open a URL itself, including after a handler is removed.
        return true
    }
}

final class AppKitBubbleTextView: NSTextView {
    let contentLayout: BubbleTextLayout
    var failureAction: (() -> Void)? {
        didSet { updateFailureButton() }
    }
    private var failureButton: NSButton?

    init() {
        let layout = BubbleTextLayout()
        contentLayout = layout
        super.init(frame: .zero, textContainer: layout.textContainer)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = false
        layout.textContainer.widthTracksTextView = false
        layout.textContainer.heightTracksTextView = false
        linkTextAttributes = [:]
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { contentLayout.idealSize }

    private func updateFailureButton() {
        guard failureAction != nil, let metadata = contentLayout.metadata, metadata.state == .failed else {
            failureButton?.removeFromSuperview()
            failureButton = nil
            return
        }
        let button: NSButton
        if let failureButton {
            button = failureButton
        } else {
            button = NSButton(frame: .zero)
            button.title = ""
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyUpOrDown
            button.setButtonType(.momentaryPushIn)
            button.target = self
            button.action = #selector(openFailureOptions)
            button.setAccessibilityLabel(String(localized: "Failed to send. Retry options"))
            button.setAccessibilityElement(true)
            addSubview(button)
            failureButton = button
        }
        button.image = metadata.symbol
        needsLayout = true
    }

    @objc private func openFailureOptions() {
        guard contentLayout.metadata?.state == .failed else { return }
        failureAction?()
    }

    override func layout() {
        super.layout()
        let geometry = contentLayout.geometry(for: bounds.width)
        if let metadata = contentLayout.metadata {
            failureButton?.frame = metadata.symbolFrame(in: geometry.metadataFrame)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let geometry = contentLayout.geometry(for: bounds.width)
        super.draw(dirtyRect)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            contentLayout.metadata?.draw(in: geometry.metadataFrame, drawsSymbol: failureButton == nil)
        }
    }

    override func accessibilityValue() -> String? {
        guard let metadata = contentLayout.metadata else { return super.accessibilityValue() }
        return "\(string) \(metadata.accessibilityLabel)"
    }

    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if let failureButton, !children.contains(where: { ($0 as? NSView) === failureButton }) {
            children.append(failureButton)
        }
        return children
    }
}
#endif
