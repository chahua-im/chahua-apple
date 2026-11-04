#if os(macOS)
    import AppKit

    /// Cached row geometry is authoritative. Native children avoid per-cell SwiftUI
    /// AttributeGraph/layout work measured in the full-content scrolling fixture.
    @MainActor
    final class TimelineTableCellView: NSTableCellView {
        let rowView = TimelineRowView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addSubview(rowView)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isFlipped: Bool { true }

        func bind(_ binding: TimelineRowBinding) {
            rowView.bind(binding)
            rowView.frame = bounds
            updateVisibility()
        }

        func clear() { rowView.clear() }

        override func layout() {
            super.layout()
            rowView.frame = bounds
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

        func updateVisibility() {
            guard window != nil, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else {
                rowView.setVisible(false)
                return
            }
            guard let scrollView = enclosingScrollView, let document = scrollView.documentView
            else {
                rowView.setVisible(false)
                return
            }
            // Native visibleRect includes rows under SwiftUI's floating chrome.
            // Keep those rows rendered for blur, but pause covered media using
            // the same public AppKit content-inset geometry as read reporting.
            let visible = scrollView.documentVisibleRect
            let insets = scrollView.contentInsets
            let unobscured = NSRect(
                x: visible.minX + insets.left,
                y: visible.minY + insets.top,
                width: max(0, visible.width - insets.left - insets.right),
                height: max(0, visible.height - insets.top - insets.bottom))
            rowView.setVisible(
                !unobscured.isEmpty && convert(unobscured, from: document).intersects(visibleRect))
        }
    }
#endif
