import SwiftUI

/// A non-hit-testing marker scopes context gestures to the bubble surface.
/// iOS shares the row's touch decision; macOS retains native context monitoring.
struct MessageContextSource: ViewModifier {
    var open: ((CGRect) -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let open {
            content.background {
                GeometryReader { _ in
                    #if os(macOS)
                        MessageContextGestureBridge(open: open)
                            .accessibilityHidden(true)
                    #else
                        MessageBubbleHoldSource(open: open)
                            .accessibilityHidden(true)
                    #endif
                }
            }
            .accessibilityAction(named: Text("Message actions")) { open(.zero) }
        } else {
            content
        }
    }
}

#if os(macOS)
    import AppKit

    private struct MessageContextGestureBridge: NSViewRepresentable {
        let open: (CGRect) -> Void
        func makeNSView(context: Context) -> MessageContextMarker { MessageContextMarker() }
        func updateNSView(_ view: MessageContextMarker, context: Context) { view.open = open }
        static func dismantleNSView(_ view: MessageContextMarker, coordinator: ()) { view.stop() }
    }

    private final class MessageContextMarker: NSView {
        var open: ((CGRect) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            // Intercept before NSTextView's own contextual menu consumes the event.
            // Left clicks without Control never enter this path.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
                [weak self] event in
                guard let self, let window = self.window, event.window === window,
                    event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                    !self.isHiddenOrHasHiddenAncestor,
                    self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)),
                    let open = self.open
                else { return event }
                guard let content = window.contentView else { return event }
                let rect = self.convert(self.bounds, to: content)
                open(
                    content.isFlipped
                        ? rect
                        : CGRect(
                            x: rect.minX, y: content.bounds.maxY - rect.maxY, width: rect.width, height: rect.height))
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
#endif
