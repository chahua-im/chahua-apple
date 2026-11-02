#if os(macOS)
    import AppKit
    import SwiftUI

    // macOS 14 SwiftUI scrolling exposes neither exact pull/offset restoration nor
    // AppKit's overlay-scroller style. One non-interactive viewport bridge owns
    // both native exceptions without adding per-row hosting graphs.
    struct ConversationListViewportMarker: NSViewRepresentable {
        let scrollScope: ConversationListScrollScope
        let scrollerScope: ChatListOverlayScrollerScope

        func makeNSView(context: Context) -> MarkerView {
            MarkerView(scrollScope: scrollScope, scrollerScope: scrollerScope)
        }

        func updateNSView(_ view: MarkerView, context: Context) {
            view.resolve(reconsiderHierarchy: true)
        }

        static func dismantleNSView(_ view: MarkerView, coordinator: ()) {
            view.disconnect()
        }

        final class MarkerView: NSView {
            private let scrollScope: ConversationListScrollScope
            private let scrollerScope: ChatListOverlayScrollerScope
            private weak var resolvedScrollView: NSScrollView?
            private weak var resolvedRoot: NSView?
            private weak var attachedDriver: MacConversationListScrollDriver?
            private var lastViewportSize: CGSize?
            private var needsDiscovery = true
            private var isDisconnected = false
            private var resolutionScheduled = false

            init(
                scrollScope: ConversationListScrollScope,
                scrollerScope: ChatListOverlayScrollerScope
            ) {
                self.scrollScope = scrollScope
                self.scrollerScope = scrollerScope
                super.init(frame: .zero)
            }

            required init?(coder: NSCoder) { nil }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                resolve(reconsiderHierarchy: true)
            }

            override func viewDidMoveToSuperview() {
                super.viewDidMoveToSuperview()
                resolve(reconsiderHierarchy: true)
            }

            override func layout() {
                super.layout()
                resolve()
            }

            func resolve(reconsiderHierarchy: Bool = false) {
                if reconsiderHierarchy { needsDiscovery = true }
                guard !isDisconnected, !resolutionScheduled else { return }
                let current = currentScrollView()
                // Failed discovery is retried on remount/update/resize, not on
                // every layout frame while an unsupported hierarchy is unchanged.
                if current == nil, !needsDiscovery, lastViewportSize == bounds.size {
                    return
                }
                if let scroll = current, let attachedDriver,
                    scrollScope.driver === attachedDriver, attachedDriver.scrollView === scroll,
                    lastViewportSize == bounds.size
                {
                    return
                }
                resolutionScheduled = true
                // Native configuration can tile or restore the viewport, emitting
                // synchronous clip notifications. Handoff must follow SwiftUI layout.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.resolutionScheduled = false
                    guard !self.isDisconnected else { return }
                    self.resolveNow()
                }
            }

            private func resolveNow() {
                // A newer background can adopt this driver's native view before
                // SwiftUI dismantles the old host. The old host cannot reclaim it.
                if let attachedDriver, attachedDriver.owner !== self { return }
                guard window != nil else {
                    releaseAttachment()
                    return
                }
                let scroll: NSScrollView
                if let current = currentScrollView() {
                    scroll = current
                } else if let match = findViewport() {
                    resolvedRoot = match.root
                    resolvedScrollView = match.scroll
                    scroll = match.scroll
                } else {
                    releaseAttachment()
                    needsDiscovery = false
                    lastViewportSize = bounds.size
                    return
                }
                if attachedDriver?.scrollView !== scroll || scrollScope.driver !== attachedDriver {
                    let driver: MacConversationListScrollDriver
                    if let existing = scrollScope.driver as? MacConversationListScrollDriver,
                        existing.scrollView === scroll
                    {
                        // Remounts can replace only the SwiftUI background host. Keep
                        // one observer set and the original native settings intact.
                        driver = existing
                    } else {
                        driver = MacConversationListScrollDriver(
                            scrollView: scroll, scope: scrollScope)
                    }
                    driver.owner = self
                    scrollScope.attach(driver, preservingOffset: true)
                    attachedDriver = driver
                }
                needsDiscovery = true
                lastViewportSize = bounds.size
                scrollerScope.attach(scroll, from: self)
            }

            private func currentScrollView() -> NSScrollView? {
                guard let window, let scroll = resolvedScrollView, let root = resolvedRoot,
                    scroll.window === window, scroll.documentView != nil,
                    isDescendant(of: root), scroll.isDescendant(of: root),
                    !isDescendant(of: scroll), matchesViewport(scroll)
                else { return nil }
                return scroll
            }

            private func matchesViewport(_ scroll: NSScrollView) -> Bool {
                let viewport = scroll.convert(scroll.bounds, to: self)
                return abs(viewport.minX - bounds.minX) <= 1
                    && abs(viewport.minY - bounds.minY) <= 1
                    && abs(viewport.width - bounds.width) <= 1
                    && abs(viewport.height - bounds.height) <= 1
            }

            private func findViewport() -> (root: NSView, scroll: NSScrollView)? {
                guard !bounds.isEmpty else { return nil }
                // A SwiftUI background is a sibling, not a descendant of its
                // NSScrollView. Search successive sibling branches, never the window
                // tree or an enclosing scroll view. Public geometry scopes ownership;
                // no SwiftUI class names or assumptions about hosting wrappers.
                var branch: NSView = self
                while let parent = branch.superview {
                    guard !(parent is NSScrollView) else { return nil }
                    var candidate: NSScrollView?
                    var ambiguous = false
                    for sibling in parent.subviews where sibling !== branch {
                        collectViewportScrollViews(
                            in: sibling, candidate: &candidate, ambiguous: &ambiguous)
                        if ambiguous { return nil }
                    }
                    if let candidate { return (parent, candidate) }
                    branch = parent
                }
                return nil
            }

            private func collectViewportScrollViews(
                in view: NSView, candidate: inout NSScrollView?, ambiguous: inout Bool
            ) {
                if let scroll = view as? NSScrollView {
                    if scroll.window === window, scroll.documentView != nil {
                        // Revalidate cached geometry too: a departing native view
                        // can remain alive beside its replacement during transition.
                        if matchesViewport(scroll) {
                            if candidate == nil {
                                candidate = scroll
                            } else {
                                ambiguous = true
                            }
                        }
                    }
                    // Never walk a scroll view's row/document tree.
                    return
                }
                for child in view.subviews {
                    collectViewportScrollViews(
                        in: child, candidate: &candidate, ambiguous: &ambiguous)
                    if ambiguous { return }
                }
            }

            private func releaseAttachment() {
                if let attachedDriver, attachedDriver.owner === self {
                    scrollScope.releaseNativeDriverAfterViewUpdate(attachedDriver)
                }
                scrollerScope.detach(self)
                attachedDriver = nil
                resolvedScrollView = nil
                resolvedRoot = nil
                lastViewportSize = nil
            }

            func disconnect() {
                isDisconnected = true
                releaseAttachment()
            }
        }
    }

    @MainActor
    private final class MacConversationListScrollDriver: NSObject, ConversationListScrollDriver {
        weak var scrollView: NSScrollView?
        weak var owner: ConversationListViewportMarker.MarkerView?
        private weak var scope: ConversationListScrollScope?
        private let originalNotifications: Bool
        private let originalElasticity: NSScrollView.Elasticity
        private var generation = 0
        private var callbackGeneration = 0
        private var pendingRestorationOffset: CGFloat?

        var offset: CGFloat { scrollView?.contentView.bounds.minY ?? 0 }
        var restorationOffset: CGFloat { pendingRestorationOffset ?? offset }

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

        private func handOff(_ action: @escaping (ConversationListScrollScope) -> Void) {
            let expected = callbackGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.callbackGeneration == expected, let scope = self.scope,
                    scope.driver === self
                else { return }
                action(scope)
            }
        }

        // Bounds changes also fire synchronously when SwiftUI resizes/insets List.
        // Queue every gesture event in FIFO order; dropping intermediate offsets
        // would lose the maximum pull used by search/refresh.
        @objc private func scrolled() {
            let offset = offset
            handOff { $0.didScroll(offset: offset) }
        }
        @objc private func began() {
            let offset = offset
            handOff { $0.beginGesture(offset: offset) }
        }
        @objc private func ended() { handOff { $0.endGesture() } }

        func restore(offset: CGFloat) {
            pendingRestorationOffset = offset
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
                pendingRestorationOffset = nil
                scope?.didScroll(offset: self.offset)
            }
        }

        func detach() {
            callbackGeneration &+= 1
            generation += 1
            pendingRestorationOffset = nil
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
