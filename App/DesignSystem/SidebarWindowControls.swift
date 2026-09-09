#if os(macOS)
import AppKit
import SwiftUI

/// Hosts the window's real controls, retaining their native actions and menus.
struct SidebarWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlHost { ControlHost() }
    func updateNSView(_ nsView: ControlHost, context: Context) {}

    static func dismantleNSView(_ nsView: ControlHost, coordinator: ()) {
        nsView.detach()
    }

    final class ControlHost: NSView {
        private struct Placement {
            let button: NSButton
            let parent: NSView
            let frame: NSRect
        }

        private var placements: [Placement] = []
        private weak var observedWindow: NSWindow?

        override var mouseDownCanMoveWindow: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            observedWindow = window
            NotificationCenter.default.addObserver(self, selector: #selector(enterFullScreen), name: NSWindow.didEnterFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(leaveFullScreen), name: NSWindow.didExitFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification, object: window)
            install()
        }

        private func install() {
            guard placements.isEmpty, let window, !window.styleMask.contains(.fullScreen) else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
                placements.append(Placement(button: button, parent: parent, frame: button.frame))
                addSubview(button)
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            var x: CGFloat = 16
            for placement in placements {
                let size = placement.frame.size
                placement.button.setFrameOrigin(NSPoint(x: x, y: (bounds.height - size.height) / 2))
                x += size.width + 8
            }
        }

        private func restore() {
            for placement in placements {
                placement.parent.addSubview(placement.button)
                placement.button.frame = placement.frame
            }
            placements.removeAll()
        }

        @objc private func enterFullScreen() { restore() }
        @objc private func leaveFullScreen() { install() }

        @objc private func windowDidResize() {
            // AppKit also lays out standard buttons when the window resizes.
            needsLayout = true
            layoutSubtreeIfNeeded()
        }

        func detach() {
            if let observedWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: observedWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: observedWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: observedWindow)
            }
            observedWindow = nil
            restore()
        }
    }
}
#endif
