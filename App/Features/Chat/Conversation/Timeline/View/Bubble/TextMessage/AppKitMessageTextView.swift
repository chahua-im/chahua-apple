#if os(macOS)
import AppKit
import SwiftUI

extension MessageTextContent: NSViewRepresentable {
    func makeNSView(context: Context) -> AppKitMessageTextView {
        let view = AppKitMessageTextView(geometry: geometry)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: AppKitMessageTextView, context: Context) {
        let selection = view.selectedRange()
        let geometryChanged = update(view.contentLayout, coordinator: context.coordinator)
        if selection.location != NSNotFound {
            let length = view.contentLayout.storage.length
            let location = min(selection.location, length)
            let clampedSelection = NSRange(location: location, length: min(selection.length, length - location))
            if view.selectedRange() != clampedSelection {
                view.setSelectedRange(clampedSelection)
            }
        }
        view.failureAction = failureAction
        if geometryChanged {
            view.needsLayout = true
            view.invalidateIntrinsicContentSize()
        }
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppKitMessageTextView, context: Context) -> CGSize? {
        nsView.contentLayout.assignedSize
    }
}

extension MessageTextContent.Coordinator: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let storage = textView.textStorage { activateLink(in: storage, at: charIndex) }
        // Never let AppKit open a URL itself, including after a handler is removed.
        return true
    }
}

final class AppKitMessageTextView: NSTextView {
    let contentLayout: MessageTextLayout
    var failureAction: (() -> Void)? {
        didSet { updateFailureButton() }
    }
    private var failureButton: NSButton?

    init(geometry: MessageTextGeometry) {
        let layout = MessageTextLayout()
        layout.install(geometry: geometry)
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
        // Keep bubble colors, but retain AppKit's link cursor attribute so native
        // text selection and link hovering use the same cursor handling.
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { contentLayout.assignedSize }
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
            button = BubbleFailureButton(frame: .zero)
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
        guard let geometry = contentLayout.assignedGeometry else { return }

        if let metadata = contentLayout.metadata {
            failureButton?.frame = metadata.symbolFrame(in: geometry.metadataFrame)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let geometry = contentLayout.assignedGeometry else { return }
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
private final class BubbleFailureButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
#endif
