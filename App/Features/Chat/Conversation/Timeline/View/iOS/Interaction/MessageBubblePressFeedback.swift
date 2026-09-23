#if os(iOS)
    import UIKit

    /// Native feedback stays inside the existing row recognizer: SwiftUI press
    /// gestures cannot share its pre-recognition scroll/text arbitration. Animate
    /// only the bubble, then hand its presentation state to the window preview.
    @MainActor
    final class MessageBubblePressFeedback {
        static let holdDuration: TimeInterval = 0.45
        private enum Phase { case pressing, committed, hidden, restoring, restored }

        private weak var view: UIView?
        private var animator: UIViewPropertyAnimator?
        private var phase = Phase.pressing
        private(set) var scale: CGFloat = 1
        private(set) var opacity: CGFloat = 1

        init(view: UIView) {
            self.view = view
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            let animator = UIViewPropertyAnimator(
                duration: reduceMotion ? 0.12 : 0.38, curve: .easeOut
            ) { [weak view] in
                view?.transform =
                    reduceMotion ? .identity : CGAffineTransform(scaleX: 0.975, y: 0.975)
                view?.alpha = reduceMotion ? 0.88 : 1
            }
            self.animator = animator
            animator.startAnimation()
        }

        /// Freeze the rendered value, not the animation's already-set destination.
        /// The source remains pressed until the identical preview frame is mounted.
        func commit() {
            guard phase == .pressing, let view else { return }
            freeze(view)
            scale = view.transform.a
            opacity = view.alpha
            phase = .committed
        }

        func handOff() {
            guard phase == .committed, let view else { return }
            phase = .hidden
            UIView.performWithoutAnimation {
                view.alpha = 0
                view.transform = .identity
            }
        }

        func cancelPending(animated: Bool) {
            guard phase == .pressing else { return }
            restore(animated: animated)
        }

        /// Also used before row reuse/detachment, even after the overlay took over.
        /// Dropping the view after restoration prevents a stale menu from touching a
        /// bubble that has since been rebound to another message.
        func restore(animated: Bool = false) {
            guard phase != .restored, let view else { return }
            freeze(view)
            if animated, phase != .hidden, view.window != nil {
                phase = .restoring
                let animator = UIViewPropertyAnimator(duration: 0.16, curve: .easeOut) {
                    [weak view] in
                    view?.transform = .identity
                    view?.alpha = 1
                }
                self.animator = animator
                animator.addCompletion { [weak self] _ in
                    guard let self, self.phase == .restoring else { return }
                    self.phase = .restored
                    self.animator = nil
                    self.view = nil
                }
                animator.startAnimation()
            } else {
                phase = .restored
                UIView.performWithoutAnimation {
                    view.transform = .identity
                    view.alpha = 1
                }
                self.view = nil
            }
        }

        private func freeze(_ view: UIView) {
            let transform = view.layer.presentation()?.affineTransform() ?? view.transform
            let alpha = view.layer.presentation().map { CGFloat($0.opacity) } ?? view.alpha
            animator?.stopAnimation(true)
            animator = nil
            UIView.performWithoutAnimation {
                view.transform = transform
                view.alpha = alpha
            }
        }
    }
#endif
