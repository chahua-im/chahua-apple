#if os(macOS)
    import AppKit
    import SwiftUI

    /// SwiftUI has no wheel-device discrimination hook. Keep precise trackpad events native,
    /// and translate discrete vertical wheel input only over the horizontal pack strip.
    struct StickerPackWheelScrollMarker: NSViewRepresentable {
        func makeNSView(context: Context) -> WheelMarker { WheelMarker() }
        func updateNSView(_ view: WheelMarker, context: Context) {}
        static func dismantleNSView(_ view: WheelMarker, coordinator: ()) { view.stopMonitoring() }

        final class WheelMarker: NSView {
            private var monitor: Any?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                stopMonitoring()
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                    [weak self] event in
                    // Only a Sendable decision leaves the actor-isolated closure;
                    // AppKit's NSEvent stays within its synchronous monitor callback.
                    let consumed = MainActor.assumeIsolated {
                        guard let self else { return false }
                        return self.route(event) == nil
                    }
                    return consumed ? nil : event
                }
            }

            func stopMonitoring() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }

            func route(_ event: NSEvent) -> NSEvent? {
                guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0,
                    event.scrollingDeltaY != 0, let scroll = enclosingScrollView,
                    let window, event.window === window,
                    scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)),
                    let document = scroll.documentView
                else { return event }
                let clip = scroll.contentView
                let lower = document.bounds.minX
                let upper = max(lower, document.bounds.maxX - clip.bounds.width)
                var origin = clip.bounds.origin
                // Non-precise deltas are line units, not pixels.
                origin.x = min(
                    upper,
                    max(lower, origin.x - event.scrollingDeltaY * scroll.horizontalLineScroll))
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
                return nil
            }
        }
    }
#endif
