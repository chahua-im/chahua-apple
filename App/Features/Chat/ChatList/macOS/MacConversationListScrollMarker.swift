#if os(macOS)
    import AppKit
    import SwiftUI

    // SwiftUI List on macOS 14 has no pull-distance callback. Observe only this
    // List's clip view and live-scroll notifications; never replace its delegate.
    struct ConversationListScrollMarker: NSViewRepresentable {
        let scope: ConversationListScrollScope
        var keepsScopeAlive = false

        func makeNSView(context: Context) -> MarkerView {
            MarkerView(scope: scope, keepsScopeAlive: keepsScopeAlive)
        }

        func updateNSView(_ view: MarkerView, context: Context) { view.resolve() }

        static func dismantleNSView(_ view: MarkerView, coordinator: ()) {
            if view.keepsScopeAlive { view.scope.detach() }
        }

        final class MarkerView: NSView {
            let scope: ConversationListScrollScope
            let keepsScopeAlive: Bool

            init(scope: ConversationListScrollScope, keepsScopeAlive: Bool) {
                self.scope = scope
                self.keepsScopeAlive = keepsScopeAlive
                super.init(frame: .zero)
            }

            required init?(coder: NSCoder) { nil }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                resolve()
            }
            override func viewDidMoveToSuperview() {
                super.viewDidMoveToSuperview()
                resolve()
            }
            override func layout() {
                super.layout()
                resolve()
            }

            func resolve() {
                if keepsScopeAlive { return }
                guard window != nil, let scroll = enclosingScrollView else { return }
                if (scope.driver as? MacConversationListScrollDriver)?.scrollView !== scroll {
                    scope.attach(MacConversationListScrollDriver(scrollView: scroll, scope: scope))
                }
            }
        }
    }

    @MainActor
    private final class MacConversationListScrollDriver: NSObject, ConversationListScrollDriver {
        weak var scrollView: NSScrollView?
        private weak var scope: ConversationListScrollScope?
        private let originalNotifications: Bool
        private let originalElasticity: NSScrollView.Elasticity
        private var generation = 0

        var offset: CGFloat { scrollView?.contentView.bounds.minY ?? 0 }

        init(scrollView: NSScrollView, scope: ConversationListScrollScope) {
            self.scrollView = scrollView
            self.scope = scope
            originalNotifications = scrollView.contentView.postsBoundsChangedNotifications
            originalElasticity = scrollView.verticalScrollElasticity
            super.init()
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.verticalScrollElasticity = .allowed
            let notifications = NotificationCenter.default
            notifications.addObserver(
                self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
            notifications.addObserver(
                self, selector: #selector(began),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView)
            notifications.addObserver(
                self, selector: #selector(ended), name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView)
        }

        @objc private func scrolled() { scope?.didScroll(offset: offset) }
        @objc private func began() { scope?.beginGesture() }
        @objc private func ended() { scope?.endGesture() }

        func restore(offset: CGFloat) {
            generation += 1
            let expected = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == expected, let scrollView else { return }
                scrollView.layoutSubtreeIfNeeded()
                let maximum = max(
                    0,
                    (scrollView.documentView?.bounds.height ?? 0)
                        - scrollView.contentView.bounds.height)
                scrollView.contentView.scroll(
                    to: CGPoint(
                        x: scrollView.contentView.bounds.minX,
                        y: min(maximum, max(0, offset))))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                scope?.didScroll(offset: self.offset)
            }
        }

        func detach() {
            generation += 1
            NotificationCenter.default.removeObserver(self)
            if let scrollView {
                if scrollView.contentView.postsBoundsChangedNotifications {
                    scrollView.contentView.postsBoundsChangedNotifications = originalNotifications
                }
                if scrollView.verticalScrollElasticity == .allowed {
                    scrollView.verticalScrollElasticity = originalElasticity
                }
            }
            scope = nil
            scrollView = nil
        }
    }
#endif
