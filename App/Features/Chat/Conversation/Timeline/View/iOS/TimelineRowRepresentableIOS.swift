#if os(iOS)
    import SwiftUI
    import UIKit

    /// SwiftUI boundary for the gallery and the single action preview only.
    /// Production collection cells mount TimelineRowView directly, without hosting.
    struct TimelineRowRepresentable: UIViewRepresentable {
        let presentation: TimelineRowPresentation
        let layout: TimelineRowLayout
        let context: TimelineRowContext
        var actions: TimelineBubbleActions = .init()
        var mediaContext: AppMediaContext?

        private var binding: TimelineRowBinding {
            .init(
                presentation: presentation, layout: layout, context: context, actions: actions,
                mediaContext: mediaContext)
        }
        private var size: CGSize {
            context.isInteractionPreview ? layout.frames[.bubble]?.size ?? layout.size : layout.size
        }
        func makeUIView(context: Context) -> TimelineRowView {
            let view = TimelineRowView(frame: CGRect(origin: .zero, size: size))
            view.bind(binding)
            return view
        }
        func updateUIView(_ view: TimelineRowView, context: Context) {
            view.bind(binding)
            view.setVisible(view.window != nil && !view.isHidden)
        }
        func sizeThatFits(_ proposal: ProposedViewSize, uiView: TimelineRowView, context: Context)
            -> CGSize?
        { size }
        static func dismantleUIView(_ view: TimelineRowView, coordinator: ()) { view.clear() }
    }
#endif
