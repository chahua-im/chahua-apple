#if os(macOS)
import AppKit
import SwiftUI

/// Fixture-gallery boundary only. Production cells and action previews mount the
/// native row/bubble directly, without a SwiftUI subtree or a hosting view.
struct TimelineRowRepresentable: NSViewRepresentable {
    let presentation: TimelineRowPresentation
    let layout: TimelineRowLayout
    let context: TimelineRowContext
    let actions: TimelineBubbleActions
    let mediaContext: AppMediaContext?

    init(presentation: TimelineRowPresentation, layout: TimelineRowLayout, context: TimelineRowContext,
         actions: TimelineBubbleActions = .init(), mediaContext: AppMediaContext? = nil) {
        self.presentation = presentation
        self.layout = layout
        self.context = context
        self.actions = actions
        self.mediaContext = mediaContext
    }

    private var binding: TimelineRowBinding {
        .init(presentation: presentation, layout: layout, context: context, actions: actions, mediaContext: mediaContext)
    }

    func makeNSView(context: Context) -> TimelineRowView {
        let view = TimelineRowView(frame: CGRect(origin: .zero, size: layout.size))
        view.bind(binding)
        return view
    }

    func updateNSView(_ view: TimelineRowView, context: Context) {
        view.bind(binding)
        view.setVisible(view.window != nil && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineRowView, context: Context) -> CGSize? { layout.size }

    static func dismantleNSView(_ view: TimelineRowView, coordinator: ()) {
        view.setVisible(false)
        view.clear()
    }
}
#endif
