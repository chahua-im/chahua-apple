#if os(macOS)
    import AppKit
    import SwiftUI

    /// SwiftUI DragGesture describes mouse drags, not trackpad scroll phases.
    /// A window-scoped AppKit monitor claims only a rightward two-finger gesture
    /// before row scroll handlers see it; vertical scrolling and leftward row actions
    /// remain native. The sidebar's SwiftUI tree still owns all presentation.
    struct MacSidebarBackGesture: NSViewRepresentable {
        var isEnabled: Bool
        let onChange: (CGFloat) -> Void
        let onFinish: (Bool) -> Void

        func makeNSView(context: Context) -> Marker { Marker() }

        func updateNSView(_ view: Marker, context: Context) {
            view.isEnabled = isEnabled
            view.onChange = onChange
            view.onFinish = onFinish
        }

        static func dismantleNSView(_ view: Marker, coordinator: ()) {
            view.stopMonitoring()
        }

        final class Marker: NSView {
            var isEnabled = false
            var onChange: ((CGFloat) -> Void)?
            var onFinish: ((Bool) -> Void)?
            private var monitor: Any?
            private enum Axis { case idle, pending, back, other }
            private var axis = Axis.idle
            private var translation = CGPoint.zero
            private var suppressMomentum = false
            private var lastDelta: CGFloat = 0

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                stopMonitoring()
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                    [weak self] event in
                    let consumed = MainActor.assumeIsolated {
                        self?.route(event) ?? false
                    }
                    return consumed ? nil : event
                }
                NotificationCenter.default.addObserver(
                    self, selector: #selector(cancelGesture),
                    name: NSWindow.didResignKeyNotification, object: window)
            }

            func stopMonitoring() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                NotificationCenter.default.removeObserver(self)
                axis = .idle
                suppressMomentum = false
            }

            @objc private func cancelGesture() {
                let wasBack = axis == .back
                axis = .idle
                suppressMomentum = false
                if wasBack { onFinish?(false) }
            }

            private func route(_ event: NSEvent) -> Bool {
                guard let window, event.window === window else { return false }
                if !event.momentumPhase.isEmpty {
                    let consumed = suppressMomentum
                    if event.momentumPhase.contains(.ended)
                        || event.momentumPhase.contains(.cancelled)
                    {
                        suppressMomentum = false
                    }
                    return consumed
                }
                guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else { return false }
                if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                    // Coordinate checks stay local to this sidebar, never the detail pane.
                    guard isEnabled, window.attachedSheet == nil,
                        bounds.contains(convert(event.locationInWindow, from: nil))
                    else {
                        axis = .idle
                        return false
                    }
                    axis = .pending
                    translation = .zero
                    lastDelta = 0
                    suppressMomentum = false
                }
                guard axis != .idle else { return false }
                if !isEnabled, axis != .back {
                    axis = .idle
                    return false
                }
                if event.phase.contains(.cancelled) {
                    let consumed = axis == .back
                    axis = .idle
                    suppressMomentum = consumed
                    if consumed { onFinish?(false) }
                    return consumed
                }
                translation.x += event.scrollingDeltaX
                translation.y += event.scrollingDeltaY
                if axis == .pending, max(abs(translation.x), abs(translation.y)) >= 3 {
                    axis = translation.x > abs(translation.y) * 1.2 ? .back : .other
                }
                let consumed = axis == .back
                if consumed {
                    if event.scrollingDeltaX != 0 { lastDelta = event.scrollingDeltaX }
                    onChange?(max(0, translation.x))
                }
                if event.phase.contains(.ended) {
                    axis = .idle
                    suppressMomentum = consumed
                    if consumed {
                        let committed =
                            translation.x >= bounds.width * 0.35
                            || (translation.x > 20 && lastDelta > 8)
                        onFinish?(committed)
                    }
                }
                return consumed
            }
        }
    }
#endif
