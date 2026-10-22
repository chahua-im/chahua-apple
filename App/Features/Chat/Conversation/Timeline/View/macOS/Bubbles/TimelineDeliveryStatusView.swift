#if os(macOS)
    import AppKit
    import SwiftUI

    /// TextKit selection and cached timeline geometry require native row ownership;
    /// hosting the row in SwiftUI would replace that selection/layout machinery. Only
    /// the shared delivery status is hosted, with AppKit retaining frame authority.
    @MainActor
    final class TimelineDeliveryStatusView: NSView {
        private var host: NSHostingView<MessageDeliveryStatusContent>?
        private var hasContent = false
        private var requestedVisible = true

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
            setAccessibilityHidden(true)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ metadata: MessageMetadata?) {
            guard var content = metadata?.statusContent else {
                hasContent = false
                isHidden = true
                updateVisibility()
                return
            }
            hasContent = true
            isHidden = false
            content.isVisible = contentIsVisible
            if let host {
                host.rootView = content
            } else {
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                host.setAccessibilityElement(false)
                host.setAccessibilityHidden(true)
                addSubview(host)
                self.host = host
            }
            needsLayout = true
        }

        func setVisible(_ visible: Bool) {
            requestedVisible = visible
            updateVisibility()
        }

        // The timestamp/text view and transparent native retry button own interaction
        // and accessibility. The SwiftUI decoration must never intercept text selection.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            // The shared content scales its nominal size to these fitted native bounds.
            host?.frame = bounds
            updateVisibility()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateVisibility()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateVisibility()
        }

        override func viewDidHide() {
            super.viewDidHide()
            updateVisibility()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            updateVisibility()
        }

        private var contentIsVisible: Bool {
            hasContent && requestedVisible && window != nil
                && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
        }

        private func updateVisibility() {
            guard let host, host.rootView.isVisible != contentIsVisible else { return }
            var content = host.rootView
            // Removing the shared component from the retained host stops its spinner,
            // including when a recycled row remains attached to the native table.
            content.isVisible = contentIsVisible
            host.rootView = content
        }
    }
#endif
