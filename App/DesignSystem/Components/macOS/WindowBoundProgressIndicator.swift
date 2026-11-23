#if os(macOS)
    import AppKit

    /// AppKit timeline and media hosts need a native indicator, not a SwiftUI host per row.
    /// NSProgressIndicator can retain a blocking animation worker after an offscreen start.
    /// Defer animation until attachment and stop it on hide/detach so discarded loading views
    /// cannot exhaust the process-wide dispatch pool and stall unrelated item providers.
    @MainActor
    final class WindowBoundProgressIndicator: NSProgressIndicator {
        private var animationRequested = false
        private var animationRunning = false
        private static let visibilityNotifications = [
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]

        override func startAnimation(_ sender: Any?) {
            animationRequested = true
            updateAnimation()
        }

        override func stopAnimation(_ sender: Any?) {
            animationRequested = false
            updateAnimation()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, animationRunning {
                animationRunning = false
                super.stopAnimation(nil)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for name in Self.visibilityNotifications {
                NotificationCenter.default.removeObserver(self, name: name, object: nil)
                if let window {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(updateAnimation), name: name, object: window)
                }
            }
            updateAnimation()
        }

        override func viewDidHide() {
            super.viewDidHide()
            updateAnimation()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            updateAnimation()
        }

        @objc private func updateAnimation() {
            let shouldAnimate =
                animationRequested && !isHiddenOrHasHiddenAncestor
                && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true
            guard shouldAnimate != animationRunning else { return }
            animationRunning = shouldAnimate
            if shouldAnimate {
                super.startAnimation(nil)
            } else {
                super.stopAnimation(nil)
            }
        }
    }
#endif
