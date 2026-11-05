#if os(iOS)
    import SwiftUI
    import UIKit

    // SwiftUI List on iOS 17 does not expose pull distance. KVO and a passive pan
    // target preserve UIKit's own List delegate, row swipes, and scroll gestures.
    struct ConversationListScrollMarker: UIViewRepresentable {
        let scope: ConversationListScrollScope
        var keepsScopeAlive = false

        func makeUIView(context: Context) -> MarkerView {
            MarkerView(scope: scope, keepsScopeAlive: keepsScopeAlive)
        }

        func updateUIView(_ view: MarkerView, context: Context) { view.resolve() }

        static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
            view.detach()
        }

        final class MarkerView: UIView {
            let scope: ConversationListScrollScope
            let keepsScopeAlive: Bool
            private var detached = false
            private var resolutionQueued = false

            init(scope: ConversationListScrollScope, keepsScopeAlive: Bool) {
                self.scope = scope
                self.keepsScopeAlive = keepsScopeAlive
                super.init(frame: .zero)
                isUserInteractionEnabled = false
            }

            required init?(coder: NSCoder) { nil }
            override func didMoveToWindow() {
                super.didMoveToWindow()
                resolve()
            }
            override func didMoveToSuperview() {
                super.didMoveToSuperview()
                resolve()
            }
            override func layoutSubviews() {
                super.layoutSubviews()
                resolve()
            }

            func resolve() {
                guard !detached, !resolutionQueued else { return }
                resolutionQueued = true
                // Resolving a List ancestor can install KVO while SwiftUI is
                // laying it out. Native/model handoffs belong to the next turn.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    resolutionQueued = false
                    guard !detached else { return }
                    resolveNow()
                }
            }

            func detach() {
                detached = true
                if keepsScopeAlive { scope.detachAfterViewUpdate() }
            }

            private func resolveNow() {
                if keepsScopeAlive { return }
                guard window != nil else { return }
                var ancestor = superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView {
                        if (scope.driver as? IOSConversationListScrollDriver)?.scrollView !== scroll
                        {
                            scope.attach(
                                IOSConversationListScrollDriver(scrollView: scroll, scope: scope))
                        }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }

    @MainActor
    private final class IOSConversationListScrollDriver: NSObject, ConversationListScrollDriver {
        weak var scrollView: UIScrollView?
        private weak var scope: ConversationListScrollScope?
        private var observation: NSKeyValueObservation?
        private let originalBounce: Bool
        private var generation = 0
        private var pendingOffset: CGFloat?
        private var opening: CGFloat = 0
        private var gestureOpening: CGFloat = 0
        private var gestureOffset: CGFloat = 0
        private var handlesPrototypeGesture = false
        private var applyingOpening = false
        private var displayLink: CADisplayLink?
        private var tweenStart: CFTimeInterval = 0
        private var tweenDuration: TimeInterval = 0
        private var tweenFrom: CGFloat = 0
        private var tweenTo: CGFloat = 0
        private var tweenKeepsAtTop = false

        var restorationOffset: CGFloat { pendingOffset ?? max(0, offset) }

        var offset: CGFloat {
            guard let scrollView else { return 0 }
            return scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        }

        init(scrollView: UIScrollView, scope: ConversationListScrollScope) {
            self.scrollView = scrollView
            self.scope = scope
            originalBounce = scrollView.alwaysBounceVertical
            super.init()
            scrollView.alwaysBounceVertical = true
            observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard !self.applyingOpening else { return }
                    let offset = self.offset
                    self.enqueue { scope in
                        // Prototype drags use un-rubber-banded pan translation,
                        // not UIKit's already resisted contentOffset.
                        if !scope.prototypePullEnabled { scope.didScroll(offset: offset) }
                    }
                }
            }
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
        }

        @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
            let state = recognizer.state
            let offset = self.offset
            let translation = recognizer.translation(in: scrollView).y
            enqueue { [weak self] scope in
                guard let self else { return }
                if scope.prototypePullEnabled {
                    handlePrototypePan(
                        state: state, translation: translation, offset: offset, scope: scope)
                } else {
                    switch state {
                    case .began: scope.beginGesture(offset: offset)
                    case .ended: scope.endGesture()
                    case .cancelled, .failed: scope.endGesture(cancelled: true)
                    default: break
                    }
                }
            }
        }

        private func handlePrototypePan(
            state: UIGestureRecognizer.State, translation: CGFloat, offset: CGFloat,
            scope: ConversationListScrollScope
        ) {
            switch state {
            case .began:
                guard !scope.isRefreshing else { return }
                stopTween()
                handlesPrototypeGesture = true
                gestureOpening = opening
                gestureOffset = max(0, offset)
                scope.beginGesture(offset: offset)
            case .changed, .ended:
                guard handlesPrototypeGesture else { return }
                let raw = gestureOpening + translation - gestureOffset
                let wasOpen = opening > 0
                scope.didScroll(offset: -max(0, raw))
                if raw < 0, wasOpen, !scope.isSearchPinned, let scrollView {
                    scrollView.setContentOffset(
                        CGPoint(
                            x: scrollView.contentOffset.x,
                            y: -scrollView.adjustedContentInset.top - raw), animated: false)
                }
                if state == .ended {
                    handlesPrototypeGesture = false
                    scope.endGesture()
                }
            case .cancelled, .failed:
                guard handlesPrototypeGesture else { return }
                handlesPrototypeGesture = false
                scope.endGesture(cancelled: true)
            default: break
            }
        }

        // SwiftUI cannot independently animate List's native overscroll and its
        // overlay on iOS 17. One display link drives both with the prototype's
        // cubic easing, while retaining the List delegate and swipe recognizers.
        func setPrototypeOpening(_ opening: CGFloat, duration: TimeInterval) {
            stopTween()
            let target = max(0, opening)
            guard duration > 0, abs(target - self.opening) > 0.01 else {
                applyOpening(target)
                return
            }
            tweenFrom = self.opening
            tweenTo = target
            tweenDuration = duration
            tweenStart = CACurrentMediaTime()
            tweenKeepsAtTop = offset <= 0.5 || handlesPrototypeGesture
            let link = CADisplayLink(target: self, selector: #selector(advanceTween))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func advanceTween(_ link: CADisplayLink) {
            guard let scope, scope.driver === self else {
                stopTween()
                return
            }
            let progress = min(1, max(0, (CACurrentMediaTime() - tweenStart) / tweenDuration))
            let eased =
                progress < 0.5
                ? 4 * progress * progress * progress : 1 - pow(-2 * progress + 2, 3) / 2
            applyOpening(
                tweenFrom + (tweenTo - tweenFrom) * CGFloat(eased), keepsAtTop: tweenKeepsAtTop)
            if progress == 1 { stopTween() }
        }

        private func applyOpening(_ next: CGFloat, keepsAtTop: Bool = false) {
            guard let scrollView else { return }
            if next == opening, !keepsAtTop {
                scope?.didUpdatePrototypeOpening(next)
                return
            }
            let logicalOffset = max(0, offset)
            applyingOpening = true
            var inset = scrollView.contentInset
            let delta = next - opening
            inset.top += delta
            opening = next
            scrollView.contentInset = inset
            // The inset is the sole drawer spacer. Keep the native scroll
            // indicator below it too; no duplicate SwiftUI safe-area inset.
            var indicatorInset = scrollView.verticalScrollIndicatorInsets
            indicatorInset.top += delta
            scrollView.verticalScrollIndicatorInsets = indicatorInset
            if keepsAtTop || handlesPrototypeGesture && (next > 0 || logicalOffset == 0) {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                    animated: false)
            } else {
                scrollView.setContentOffset(
                    CGPoint(
                        x: scrollView.contentOffset.x,
                        y: logicalOffset - scrollView.adjustedContentInset.top), animated: false)
            }
            applyingOpening = false
            scope?.didUpdatePrototypeOpening(next)
        }

        private func stopTween() {
            displayLink?.invalidate()
            displayLink = nil
        }

        /// KVO also fires for offsets assigned by List layout, not only gestures.
        /// Queue gesture boundaries alongside offsets to retain pull/refresh order.
        private func enqueue(_ action: @escaping (ConversationListScrollScope) -> Void) {
            let expected = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == expected, let scope, scope.driver === self else {
                    return
                }
                action(scope)
            }
        }

        func restore(offset: CGFloat) {
            generation += 1
            stopTween()
            handlesPrototypeGesture = false
            pendingOffset = offset
            let expected = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == expected, let scrollView else { return }
                scrollView.layoutIfNeeded()
                let minimum = -scrollView.adjustedContentInset.top
                let maximum = max(
                    minimum,
                    scrollView.contentSize.height - scrollView.bounds.height
                        + scrollView.adjustedContentInset.bottom)
                scrollView.setContentOffset(
                    CGPoint(
                        x: scrollView.contentOffset.x,
                        y: min(maximum, max(minimum, offset + minimum))), animated: false)
                pendingOffset = nil
                scope?.didScroll(offset: self.offset)
            }
        }

        func detach() {
            generation += 1
            stopTween()
            if opening != 0, let scrollView {
                var inset = scrollView.contentInset
                inset.top -= opening
                scrollView.contentInset = inset
                var indicatorInset = scrollView.verticalScrollIndicatorInsets
                indicatorInset.top -= opening
                scrollView.verticalScrollIndicatorInsets = indicatorInset
                opening = 0
            }
            pendingOffset = nil
            handlesPrototypeGesture = false
            observation?.invalidate()
            observation = nil
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged))
            if let scrollView, scrollView.alwaysBounceVertical {
                scrollView.alwaysBounceVertical = originalBounce
            }
            scope = nil
            scrollView = nil
        }
    }
#endif
