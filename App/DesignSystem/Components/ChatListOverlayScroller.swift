#if os(macOS)
    import AppKit
    import Combine

    /// SwiftUI scrollIndicators controls visibility, not AppKit's legacy gutter.
    /// The single viewport bridge forces overlay style even for an empty list.

    @MainActor
    final class ChatListOverlayScrollerScope: NSObject, ObservableObject {
        private weak var lifetimeHost: NSView?
        private weak var scrollView: NSScrollView?
        private var originalStyle: NSScroller.Style = .legacy
        private var originalAutohides = false
        private var reconciliationScheduled = false
        private var lifetimeGeneration = 0

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(preferredStyleChanged),
                name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func attach(_ candidate: NSScrollView, from host: NSView) {
            guard let window = host.window, candidate.window === window else { return }
            lifetimeGeneration += 1
            lifetimeHost = host
            if scrollView !== candidate {
                restore()
                scrollView = candidate
                originalStyle = candidate.scrollerStyle
                originalAutohides = candidate.autohidesScrollers
            }
            reconcile()
        }

        func detach(_ host: NSView) {
            guard lifetimeHost === host else { return }
            // Stop queued reconciliation immediately, while retaining the saved
            // native policy long enough for a replacement host to adopt it.
            lifetimeHost = nil
            lifetimeGeneration += 1
            let generation = lifetimeGeneration
            // A replacement SwiftUI background can adopt the same scroll view on
            // the next turn. Preserve its original settings until adoption resolves;
            // otherwise overlay/autohide would be recaptured as native defaults.
            DispatchQueue.main.async { [weak self] in
                guard let self, lifetimeGeneration == generation else { return }
                // Dismantle must not retile a dying SwiftUI tree.
                scrollView = nil
            }
        }

        func reconcile() {
            apply()
            guard !reconciliationScheduled else { return }
            reconciliationScheduled = true
            // SwiftUI layout and AppKit's preference handling may run after this callback.
            // One coalesced pass avoids polling or observing private SwiftUI internals.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                reconciliationScheduled = false
                apply()
            }
        }

        private func apply() {
            guard lifetimeHost != nil, let scrollView else { return }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
        }

        private func restore() {
            guard let scrollView else { return }
            // Only restore when replacing a live native view, never during dismantling.
            // Settings changed by someone else win.
            if scrollView.scrollerStyle == .overlay { scrollView.scrollerStyle = originalStyle }
            if scrollView.autohidesScrollers { scrollView.autohidesScrollers = originalAutohides }
            self.scrollView = nil
        }

        @objc private func preferredStyleChanged() { reconcile() }
    }

#endif
