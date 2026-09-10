#if os(macOS)
import AppKit
import SwiftUI

/// Hosts the window's real controls, retaining their native actions and menus.
/// SwiftUI cannot position the real window buttons inside our sidebar header.
/// AppKit hosting preserves their native actions and menus; frame changes reconcile
/// ownership because SwiftUI navigation-title changes can reparent them to the title bar.
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
            let postedFrameChanges: Bool
        }

        private var placements: [Placement] = []
        private weak var observedWindow: NSWindow?
        private var reconciliationScheduled = false
        private var isPositioningButtons = false

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
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind),
                      let parent = button.superview, parent !== self else { continue }
                // Remember the current native title bar, not a superseded SwiftUI host.
                if let index = placements.firstIndex(where: { $0.button === button }) {
                    placements[index] = Placement(
                        button: button, parent: parent, frame: button.frame,
                        postedFrameChanges: placements[index].postedFrameChanges)
                } else {
                    placements.append(Placement(
                        button: button, parent: parent, frame: button.frame,
                        postedFrameChanges: button.postsFrameChangedNotifications))
                }
                button.postsFrameChangedNotifications = true
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: button)
                NotificationCenter.default.addObserver(self, selector: #selector(buttonFrameDidChange), name: NSView.frameDidChangeNotification, object: button)
                addSubview(button)
                needsLayout = true
            }
        }

        override func layout() {
            super.layout()
            isPositioningButtons = true
            defer { isPositioningButtons = false }
            var x: CGFloat = 16
            for placement in placements {
                guard placement.button.superview === self else { continue }
                let size = placement.frame.size
                placement.button.setFrameOrigin(NSPoint(x: x, y: (bounds.height - size.height) / 2))
                x += size.width + 8
            }
        }

        private func restore() {
            for placement in placements {
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: placement.button)
                placement.button.postsFrameChangedNotifications = placement.postedFrameChanges
                guard placement.button.superview === self else { continue }
                placement.parent.addSubview(placement.button)
                placement.button.frame = placement.frame
            }
            placements.removeAll()
        }

        @objc private func enterFullScreen() { restore() }
        @objc private func leaveFullScreen() { install() }

        @objc private func buttonFrameDidChange() {
            guard !isPositioningButtons, !reconciliationScheduled else { return }
            reconciliationScheduled = true
            // Let AppKit finish its title-bar layout before reclaiming the buttons.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reconciliationScheduled = false
                guard self.observedWindow != nil else { return }
                self.install()
                self.needsLayout = true
            }
        }

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
