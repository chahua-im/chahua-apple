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
            if view.keepsScopeAlive { view.scope.detach() }
        }

        final class MarkerView: UIView {
            let scope: ConversationListScrollScope
            let keepsScopeAlive: Bool

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
                    self.scope?.didScroll(offset: self.offset)
                }
            }
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
        }

        @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began: scope?.beginGesture()
            case .ended: scope?.endGesture()
            case .cancelled, .failed: scope?.endGesture(cancelled: true)
            default: break
            }
        }

        func restore(offset: CGFloat) {
            generation += 1
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
                scope?.didScroll(offset: self.offset)
            }
        }

        func detach() {
            generation += 1
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
