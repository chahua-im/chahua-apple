#if os(macOS)
    import AppKit
    import SwiftUI

    /// A hosted waveform needs AppKit to own the left-button sequence: SwiftUI's
    /// drag can preview in a reused table row without delivering its release.
    /// The waveform drawing and accessibility controls stay in SwiftUI.
    struct VoiceWaveformPointerSurface: NSViewRepresentable {
        let isEnabled: Bool
        let preview: (CGFloat) -> Void
        let seek: (CGFloat) -> Void
        let toggle: () -> Void

        func makeNSView(context: Context) -> PointerView { PointerView() }

        func updateNSView(_ view: PointerView, context: Context) {
            view.surface = self
        }

        final class PointerView: NSView {
            var surface: VoiceWaveformPointerSurface?
            private var pressLocation: NSPoint?
            private var isScrubbing = false

            override var mouseDownCanMoveWindow: Bool { false }

            override func hitTest(_ point: NSPoint) -> NSView? {
                surface?.isEnabled == true ? super.hitTest(point) : nil
            }

            override func mouseDown(with event: NSEvent) {
                pressLocation = event.locationInWindow
                isScrubbing = false
            }

            override func mouseDragged(with event: NSEvent) {
                guard let pressLocation, let surface, surface.isEnabled else { return }
                let dx = event.locationInWindow.x - pressLocation.x
                let dy = event.locationInWindow.y - pressLocation.y
                guard isScrubbing || dx * dx + dy * dy >= 64 else { return }
                isScrubbing = true
                surface.preview(fraction(at: event))
            }

            override func mouseUp(with event: NSEvent) {
                guard pressLocation != nil else { return }
                pressLocation = nil
                defer { isScrubbing = false }
                guard let surface, surface.isEnabled else { return }
                if isScrubbing {
                    surface.seek(fraction(at: event))
                } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
                    surface.toggle()
                }
            }

            private func fraction(at event: NSEvent) -> CGFloat {
                let x = convert(event.locationInWindow, from: nil).x - bounds.minX
                return min(1, max(0, x / max(1, bounds.width)))
            }
        }
    }
#endif
