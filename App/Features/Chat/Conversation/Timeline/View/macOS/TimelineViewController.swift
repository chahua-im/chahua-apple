#if os(macOS)
    import AppKit
    import Combine
    import SwiftUI

    /// Per-row NSHostingView layout and AttributeGraph work made timeline scrolling
    /// expensive. Keep the table, state chrome and interaction preview native while
    /// preserving the shared model and the table's cached-geometry transactions.
    @MainActor
    final class TimelineViewController: NSViewController {
        private let model: ConversationTimelineModel
        private let tableController: TimelineTableViewController
        private let chromeView = TimelineChromeView()
        private let interactionController: TimelineInteractionController
        private var displayScheduler: TimelineDisplayScheduler?
        private var subscriptions = Set<AnyCancellable>()
        private var initialLoadTask: Task<Void, Never>?
        private var didRequestInitialLoad = false
        private var isTornDown = false
        private var headerInset: CGFloat = 0
        private var composerInset: CGFloat = 0
        private var colorScheme: ColorScheme = .light

        init(model: ConversationTimelineModel) {
            self.model = model
            tableController = TimelineTableViewController(model: model)
            interactionController = TimelineInteractionController(model: model)
            super.init(nibName: nil, bundle: nil)
            interactionController.onRoutedActionsChanged = { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.tableController.actions = self.interactionController.routedActions
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            let surface = TimelineSurfaceView()
            surface.windowDidChange = { [weak self] in self?.surfaceWindowDidChange() }
            view = surface
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            applyAppearance()
            addChild(tableController)
            view.addSubview(tableController.view)
            view.addSubview(chromeView)
            interactionController.timelineView = view
            // Never share this replaceable transaction slot with table layout work.
            displayScheduler = TimelineDisplayScheduler(view: view)
            model.$state.sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
            model.$rows.sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
            model.updates.sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
            let notifications = NotificationCenter.default
            notifications.addObserver(
                self, selector: #selector(windowGeometryChanged(_:)),
                name: NSWindow.didMoveNotification, object: nil)
            notifications.addObserver(
                self, selector: #selector(windowGeometryChanged(_:)),
                name: NSWindow.didResizeNotification, object: nil)
            notifications.addObserver(
                self, selector: #selector(windowGeometryChanged(_:)),
                name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
            refreshSurface()
        }

        func configure(
            actions: TimelineBubbleActions,
            interactionContext: MessageInteractionContext,
            mediaContext: AppMediaContext?,
            colorScheme: ColorScheme,
            messageTextSize: Int,
            unreadBadgeColor: ConversationUnreadBadgeColor,
            headerInset: CGFloat,
            composerInset: CGFloat,
            isSplitResizing: Bool
        ) {
            guard !isTornDown else { return }
            self.headerInset = headerInset
            self.composerInset = composerInset
            let appearanceChanged = self.colorScheme != colorScheme
            self.colorScheme = colorScheme
            tableController.isSplitResizing = isSplitResizing
            tableController.mediaContext = mediaContext
            tableController.colorScheme = colorScheme
            tableController.messageTextSize = messageTextSize
            // The table applies these as contentInsets. Chrome only positions itself;
            // neither this controller nor its representable adds another safe area.
            tableController.headerInset = headerInset
            tableController.composerInset = composerInset
            interactionController.configure(actions: actions, context: interactionContext)
            tableController.actions = interactionController.routedActions
            chromeView.setBadgeColor(unreadBadgeColor)
            if isViewLoaded {
                if appearanceChanged { applyAppearance() }
                requestRefresh()
            }
        }

        func loadInitialIfNeeded(position: TimelineInitialPosition) {
            guard !isTornDown, !didRequestInitialLoad else { return }
            didRequestInitialLoad = true
            // ChatDetail opts out and keeps ownership of model.open(position:).
            // Cancel only our awaiter on teardown, never close a feature-owned model.
            let model = model
            initialLoadTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await model.loadInitial(position: position)
                self?.initialLoadTask = nil
            }
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            tableController.view.frame = view.bounds
            chromeView.frame = view.bounds
            requestRefresh()
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            requestRefresh()
            displayScheduler?.flush()
        }

        override func viewWillDisappear() {
            super.viewWillDisappear()
            interactionController.dismiss()
            displayScheduler?.cancel()
        }

        private func requestRefresh() {
            guard isViewLoaded, !isTornDown else { return }
            displayScheduler?.request { [weak self] in self?.refreshSurface() }
        }

        private func refreshSurface() {
            guard isViewLoaded, !isTornDown else { return }
            // @Published emits before assignment. Read the current model here, on the
            // queued display turn; isAtLiveEdge is computed, not a publisher.
            chromeView.update(model: model, headerInset: headerInset, composerInset: composerInset)
            let hidesTable = !chromeView.showsTable
            if tableController.view.isHidden != hidesTable {
                tableController.view.isHidden = hidesTable
            }
            interactionController.refresh()
        }

        private func applyAppearance() {
            view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            view.wantsLayer = true
            view.layer?.backgroundColor =
                NSColor(ChahuaTheme.conversationBackground(for: colorScheme)).cgColor
        }

        private func surfaceWindowDidChange() {
            guard isViewLoaded, !isTornDown else { return }
            if view.window == nil {
                interactionController.dismiss()
                displayScheduler?.cancel()
            } else {
                requestRefresh()
            }
        }

        @objc private func windowGeometryChanged(_ notification: Notification) {
            guard isViewLoaded, let window = notification.object as? NSWindow,
                window === view.window
            else { return }
            requestRefresh()
        }

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            initialLoadTask?.cancel()
            initialLoadTask = nil
            subscriptions.removeAll()
            displayScheduler?.cancel()
            displayScheduler = nil
            chromeView.cancelPendingActions()
            interactionController.onRoutedActionsChanged = nil
            interactionController.dismiss()
            interactionController.timelineView = nil
            tableController.isSplitResizing = false
            NotificationCenter.default.removeObserver(self)
        }

        deinit {
            initialLoadTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }

    @MainActor
    private final class TimelineSurfaceView: NSView {
        var windowDidChange: (() -> Void)?
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            windowDidChange?()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            let changed = frame.origin != newOrigin
            super.setFrameOrigin(newOrigin)
            if changed { windowDidChange?() }
        }
    }
#endif
