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
            rowView.setVisible(
                window != nil && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty)
        }
    }
#endif
