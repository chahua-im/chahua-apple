#if os(macOS)
    import AppKit

    /// AppKit timeline and media hosts need a native indicator, not a SwiftUI host per row.
    /// AppKit's default threaded animation reserves dispatch workers and can starve item
    /// providers when many indicators are active. Use native timer-based animation, and
    /// suspend it while hidden/detached so offscreen loading views do no animation work.
    @MainActor
    final class WindowBoundProgressIndicator: NSProgressIndicator {
        private var animationRequested = false
        private var animationRunning = false
        private static let visibilityNotifications = [
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            usesThreadedAnimation = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            usesThreadedAnimation = false
        }

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
