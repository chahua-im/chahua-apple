#if os(macOS)
    import AppKit
    import SwiftUI

    /// Install at each window or sheet root that can contain a timeline.
    /// Native menus must stay above app chrome without touching AppKit's private frame.
    struct TimelineInteractionOverlayRoot: ViewModifier {
        func body(content: Content) -> some View {
            content.overlay {
                TimelineInteractionOverlayHost()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
        }
    }

    private struct TimelineInteractionOverlayHost: NSViewRepresentable {
        func makeNSView(context: Context) -> TimelineInteractionOverlayHostView {
            TimelineInteractionOverlayHostView()
        }

        func updateNSView(_ view: TimelineInteractionOverlayHostView, context: Context) {
            // The interaction controller, not SwiftUI state, owns this container's children.
        }
    }

    @MainActor
    final class TimelineInteractionOverlayHostView: NSView {
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }

        static func find(in view: NSView) -> TimelineInteractionOverlayHostView? {
            if let host = view as? TimelineInteractionOverlayHostView { return host }
            // The window-root overlay is above the app's other native views.
            for child in view.subviews.reversed() {
                if let host = find(in: child) { return host }
            }
            return nil
        }
    }
#endif
