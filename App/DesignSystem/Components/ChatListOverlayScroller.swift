#if os(macOS)
    import AppKit
    import Combine
    import SwiftUI

    /// SwiftUI's scrollIndicators controls visibility, not AppKit's legacy scroller gutter.
    /// List row/content insets also leave NSTableView's horizontal inter-cell spacing
    /// intact, so this same scoped bridge removes that extra row-content gutter.
    /// Content markers identify only this List's enclosing native scroll view; the List's
    /// background host keeps that configuration alive when its rows are recycled or absent.
    struct ChatListOverlayScrollerMarker: NSViewRepresentable {
        let scope: ChatListOverlayScrollerScope
        var keepsScopeAlive = false

        func makeNSView(context: Context) -> ChatListOverlayScrollerMarkerView {
            ChatListOverlayScrollerMarkerView(scope: scope, keepsScopeAlive: keepsScopeAlive)
        }

        func updateNSView(_ view: ChatListOverlayScrollerMarkerView, context: Context) {
            view.reconcile()
        }

        static func dismantleNSView(_ view: ChatListOverlayScrollerMarkerView, coordinator: ()) {
            view.detach()
        }
    }

    @MainActor
    final class ChatListOverlayScrollerScope: NSObject, ObservableObject {
        private weak var lifetimeHost: ChatListOverlayScrollerMarkerView?
        private weak var scrollView: NSScrollView?
        private weak var tableView: NSTableView?
        private var originalHorizontalSpacing: CGFloat = 0
        private var originalStyle: NSScroller.Style = .legacy
        private var originalAutohides = false
        private var reconciliationScheduled = false

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(preferredStyleChanged),
                name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func activate(_ host: ChatListOverlayScrollerMarkerView) {
            lifetimeHost = host
            reconcile()
        }

        func attach(_ candidate: NSScrollView, from marker: ChatListOverlayScrollerMarkerView) {
            guard let lifetimeHost, let window = marker.window, lifetimeHost.window === window
            else { return }
            if scrollView !== candidate {
                restore()
                scrollView = candidate
                originalStyle = candidate.scrollerStyle
                originalAutohides = candidate.autohidesScrollers
            }
            reconcile()
        }

        func detach(_ host: ChatListOverlayScrollerMarkerView) {
            guard lifetimeHost === host else { return }
            lifetimeHost = nil
            restore()
        }

        func reconcile() {
            apply()
            guard !reconciliationScheduled else { return }
            reconciliationScheduled = true
            // SwiftUI layout and AppKit's preference handling may run after this callback.
            // One coalesced pass after them avoids polling or observing private List internals.
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
            if let table = scrollView.documentView as? NSTableView {
                if tableView !== table {
                    restoreTableSpacing()
                    tableView = table
                    originalHorizontalSpacing = table.intercellSpacing.width
                }
                if table.intercellSpacing.width != 0 {
                    table.intercellSpacing.width = 0
                    // Changing spacing alone leaves the existing column at its old width.
                    table.sizeLastColumnToFit()
                }
            }
        }

        private func restore() {
            restoreTableSpacing()
            guard let scrollView else { return }
            // Row markers never restore independently. Only their List's lifetime host can
            // release the shared configuration, and settings changed by someone else win.
            if scrollView.scrollerStyle == .overlay { scrollView.scrollerStyle = originalStyle }
            if scrollView.autohidesScrollers { scrollView.autohidesScrollers = originalAutohides }
            self.scrollView = nil
        }

        private func restoreTableSpacing() {
            if let tableView, tableView.intercellSpacing.width == 0 {
                tableView.intercellSpacing.width = originalHorizontalSpacing
                tableView.sizeLastColumnToFit()
            }
            tableView = nil
        }

        @objc private func preferredStyleChanged() { reconcile() }
    }

    @MainActor
    final class ChatListOverlayScrollerMarkerView: NSView {
        private let scope: ChatListOverlayScrollerScope
        private let keepsScopeAlive: Bool
        private var detached = false
        private var reconciliationScheduled = false

        init(scope: ChatListOverlayScrollerScope, keepsScopeAlive: Bool) {
            self.scope = scope
            self.keepsScopeAlive = keepsScopeAlive
            super.init(frame: .zero)
            if keepsScopeAlive { scope.activate(self) }
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            reconcile()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reconcile()
        }

        override func layout() {
            super.layout()
            reconcile()
        }

        func reconcile() {
            guard !detached else { return }
            resolveScrollView()
            guard !reconciliationScheduled else { return }
            reconciliationScheduled = true
            // A representable can move before its hosting ancestors enter the List.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                reconciliationScheduled = false
                if !detached { resolveScrollView() }
            }
        }

        private func resolveScrollView() {
            if keepsScopeAlive {
                scope.activate(self)
            } else if let scrollView = enclosingScrollView {
                scope.attach(scrollView, from: self)
            }
        }

        func detach() {
            detached = true
            if keepsScopeAlive { scope.detach(self) }
        }
    }
#endif
