import SwiftUI

/// A non-hit-testing marker scopes native context gestures to the bubble surface.
/// Native text/media children keep their ordinary taps, drags and selection.
struct MessageContextSource: ViewModifier {
    var open: ((CGRect) -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let open {
            content.background {
                GeometryReader { _ in
                    MessageContextGestureBridge(open: open)
                        .accessibilityHidden(true)
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
#else
    import UIKit

    private struct MessageContextGestureBridge: UIViewRepresentable {
        let open: (CGRect) -> Void
        func makeUIView(context: Context) -> MessageContextMarker { MessageContextMarker() }
        func updateUIView(_ view: MessageContextMarker, context: Context) { view.open = open }
        static func dismantleUIView(_ view: MessageContextMarker, coordinator: ()) { view.stop() }
    }

    private final class MessageContextMarker: UIView, UIGestureRecognizerDelegate {
        var open: ((CGRect) -> Void)?
        private weak var gestureWindow: UIWindow?
        private lazy var hold: UILongPressGestureRecognizer = {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(held))
            gesture.minimumPressDuration = 0.45
            gesture.allowableMovement = 10
            gesture.delegate = self
            return gesture
        }()
        private lazy var secondaryClick: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(clicked))
            gesture.buttonMaskRequired = .secondary
            gesture.delegate = self
            return gesture
        }()

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            removeGestures()
            guard let window else { return }
            gestureWindow = window
            window.addGestureRecognizer(hold)
            window.addGestureRecognizer(secondaryClick)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard open != nil, let window, !isHidden, bounds.contains(touch.location(in: self)),
                owner(of: touch.view) === owner(of: self)
            else { return false }
            // Do not steal touches from a presented sheet or an already-selected text range.
            var touched = touch.view
            while let view = touched {
                if let text = view as? UITextView, text.selectedRange.length > 0 { return false }
                touched = view.superview
            }
            var ancestor: UIView? = self
            while let view = ancestor, view !== window {
                if view.isHidden || view.alpha == 0 { return false }
                if view.clipsToBounds && !view.bounds.contains(touch.location(in: view)) { return false }
                ancestor = view.superview
            }
            return true
        }

        @objc private func held() {
            if hold.state == .began {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if let window { open?(convert(bounds, to: window)) }
            }
        }
        @objc private func clicked() {
            if secondaryClick.state == .ended, let window { open?(convert(bounds, to: window)) }
        }

        private func owner(of responder: UIResponder?) -> UIViewController? {
            var candidate = responder
            while let current = candidate {
                if let controller = current as? UIViewController { return controller }
                candidate = current.next
            }
            return nil
        }
        private func removeGestures() {
            gestureWindow?.removeGestureRecognizer(hold)
            gestureWindow?.removeGestureRecognizer(secondaryClick)
            gestureWindow = nil
        }
        func stop() {
            removeGestures()
            open = nil
        }
    }
#endif
