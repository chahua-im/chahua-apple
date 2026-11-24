#if os(macOS)
    import AppKit
    import ChahuaAPI
    import Combine
    import SwiftUI

    @MainActor
    private final class TimelineScrollView: NSScrollView {
        var wheelWillScroll: (() -> Void)?
        var wheelDidScroll: (() -> Void)?

        override func scrollWheel(with event: NSEvent) {
            // Phase-less mouse wheels do not reliably send live-scroll notifications.
            wheelWillScroll?()
            super.scrollWheel(with: event)
            wheelDidScroll?()
        }
    }

    /// AppKit top-aligns a short table. A clip-view constraint keeps the live
    /// edge at the bottom without adding synthetic rows or scrollable padding.
    @MainActor
    private final class TimelineClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var bounds = super.constrainBoundsRect(proposedBounds)
            guard let table = documentView as? NSTableView, table.numberOfRows > 0,
                let scroll = enclosingScrollView
            else { return bounds }
            let height = table.rect(ofRow: table.numberOfRows - 1).maxY
            let insets = scroll.contentInsets
            if height < proposedBounds.height - insets.top - insets.bottom {
                bounds.origin.y = height - proposedBounds.height + insets.bottom
            }
            return bounds
        }
    }

    @MainActor
    final class TimelineTableViewController: NSViewController, NSTableViewDataSource,
        NSTableViewDelegate, TimelineSelectionViewportSource
    {
        private struct Geometry: Equatable {
            let size: NSSize
            let top: CGFloat
            let left: CGFloat
            let bottom: CGFloat
            let right: CGFloat
            let scale: CGFloat
            let fontSize: CGFloat

            var rowWidth: CGFloat { max(0, size.width - left - right) }
        }

        private struct EnvironmentKey: Equatable {
            let geometry: Geometry
            let textSize: Int
            let language: String
            let showAllAvatars: Bool
            let showsMessageDetails: Bool
            let isWideChatLayout: Bool
            let isSelectingMessages: Bool
            let direction: LayoutDirection
        }

        private struct Position {
            let messageID: TimelineRowID?
            let offset: CGFloat
            let originY: CGFloat
        }

        private struct ScrollAnimation {
            let start: NSPoint
            let target: NSPoint
            let startedAt: TimeInterval
            let generation: Int
            let requestID: Int?
        }

        private let model: ConversationTimelineModel
        private var rows: [TimelineRow] = []
        private let voiceReporter = VoiceTimelineReporter()
        private var voiceReferenceHeaderInset: CGFloat?
        private var isDisappearing = false
        var actions = TimelineBubbleActions() {
            didSet {
                guard !actions.hasSameRendering(as: oldValue) else { return }
                rowActions = makeRowActions()
                guard isViewLoaded else { return }
                if actions.isSelectingMessages != oldValue.isSelectingMessages {
                    preparation = nil
                    requestDisplayUpdate()
                } else {
                    refreshVisibleRoots()
                }
            }
        }
        private lazy var rowActions = makeRowActions()
        var mediaContext: AppMediaContext? {
            didSet {
                guard mediaContext !== oldValue, isViewLoaded else { return }
                refreshVisibleRoots()
            }
        }

        var colorScheme: ColorScheme = .light {
            didSet {
                guard colorScheme != oldValue, isViewLoaded else { return }
                applyConversationBackground()
            }
        }
        var isSplitResizing = false {
            didSet {
                guard isSplitResizing != oldValue else { return }
                if isSplitResizing { cancelHeightSettlement() }
                finishResizeIfPossible()
            }
        }
        var messageTextSize = MessageTextSizePreference.defaultValue {
            didSet {
                guard messageTextSize != oldValue, isViewLoaded else { return }
                preparation = nil
                requestDisplayUpdate()
            }
        }
        var appLanguage = AppLanguage.selected.rawValue {
            didSet {
                guard appLanguage != oldValue, isViewLoaded else { return }
                beginningLabel.stringValue = AppLanguage.localized("Beginning of conversation")
                preparation = nil
                requestDisplayUpdate()
            }
        }
        var showAllAvatars = ConversationTimelinePreferences.defaultShowAllAvatars {
            didSet {
                guard showAllAvatars != oldValue, isViewLoaded else { return }
                preparation = nil
                requestDisplayUpdate()
            }
        }
        var showDmDetails = ConversationTimelinePreferences.defaultShowDmDetails {
            didSet {
                guard showDmDetails != oldValue, isViewLoaded else { return }
                preparation = nil
                requestDisplayUpdate()
            }
        }
        var isWideChatLayout = false {
            didSet {
                guard isWideChatLayout != oldValue, isViewLoaded else { return }
                preparation = nil
                requestDisplayUpdate()
            }
        }
        var headerInset: CGFloat = 0 {
            didSet {
                guard headerInset != oldValue, isViewLoaded else { return }
                // SwiftUI overlays cannot supply AppKit's scroll limits. Capture
                // against the old unobscured edge before changing native padding,
                // so pin/header resizing preserves the same readable row offset.
                if installedRevision >= 0, installedGeometry == currentGeometry {
                    settledPosition = capturePosition()
                }
                scrollView.contentInsets.top = headerInset
                view.needsLayout = true
            }
        }
        var visibleHeaderInset: CGFloat? {
            didSet {
                guard visibleHeaderInset != oldValue, isViewLoaded else { return }
                requestDisplayUpdate()
            }
        }
        private var unobscuredHeaderInset: CGFloat { visibleHeaderInset ?? headerInset }
        var composerInset: CGFloat = 0 {
            didSet {
                guard composerInset != oldValue, isViewLoaded else { return }
                scrollView.contentInsets.bottom = composerInset
                view.needsLayout = true
            }
        }
        private lazy var rowCache = TimelineRowCache(
            currentUserID: model.currentUserID, isThreadTimeline: model.threadID != nil)
        /// Prepared rows backing `rows`; on-demand measurement may refresh individual entries.
        private var preparedRows: [TimelineRowID: PreparedRow] = [:]
        private var preparation: TimelineLayoutPreparation?
        private var layoutEnvironment: TimelineLayoutEnvironment?
        private var environmentCache: (key: EnvironmentKey, value: TimelineLayoutEnvironment)?
        private var displayScheduler: TimelineDisplayScheduler!
        private var scrollDisplayScheduler: TimelineDisplayScheduler?
        private var cancellable: AnyCancellable?
        private var highlightedRowID: TimelineRowID?
        private var highlightTask: Task<Void, Never>?
        private var latestSnapshot: TimelineHostSnapshot?
        private var installedRevision = -1
        private var installedWindowRevision = -1
        private var installedGeometry: Geometry?
        private var settledPosition: Position?
        private var measuredWidth: CGFloat = 0
        private var applying = false
        private var settingScrollOrigin = false
        private var handlingWheel = false
        private var selectionWheelTop: CGFloat?
        private var liveScrolling = false
        private var isTornDown = false
        private var windowLiveResizing = false
        private var liveResizing: Bool { windowLiveResizing || isSplitResizing || settlingHeights }
        private var needsFullHeightRefresh = false
        private var liveResizeRows = IndexSet()
        private var settlingHeights = false
        private var heightSettlementRevision = -1
        private var heightSettlementGeometry: Geometry?
        private var nextHeightSettlementRow = 0
        private var heightSettlementOrder: [Int] = []
        private var heightSettlementPriorityCount = 0
        private var exposedHeightChanges = IndexSet()
        private var activeRequest: TimelineScrollRequest?
        private var lastStartedRequestID: Int?
        private var scrollAnimation: ScrollAnimation?
        private var scrollGeneration = 0
        private let scrollView = TimelineScrollView()
        private let tableView = NSTableView()
        private let beginningLabel = NSTextField(labelWithString: "")
        private lazy var contextSource = TimelineContextSource(tableView: tableView)
        private let column = NSTableColumn(identifier: .init("timeline"))

        init(model: ConversationTimelineModel) {
            self.model = model
            actions = .init()
            super.init(nibName: nil, bundle: nil)
        }

        init(model: ConversationTimelineModel, actions: TimelineBubbleActions) {
            self.model = model
            self.actions = actions
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = NSView() }
        override func viewDidLoad() {
            super.viewDidLoad()
            model.selectionViewportSource = self
            applyConversationBackground()
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.hasVerticalScroller = true
            // Use the native compact overlay thumb rather than a persistent legacy gutter.
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.verticalScroller?.controlSize = .small
            scrollView.horizontalScrollElasticity = .none
            scrollView.drawsBackground = false
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentView = TimelineClipView()
            scrollView.contentView.drawsBackground = false
            // SwiftUI's floating header/pins and composer cover the full native
            // viewport. Content insets make both edges reachable without moving
            // that viewport, so rows can still render beneath the header blur.
            // AppKit already insets the overlay scroller for contentInsets;
            // setting scrollerInsets as well would count the clearance twice.
            scrollView.contentInsets.top = headerInset
            scrollView.contentInsets.bottom = composerInset
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.wheelWillScroll = { [weak self] in
                guard let self else { return }
                self.handlingWheel = true
                self.cancelForUserScroll()
                self.selectionWheelTop =
                    self.actions.isSelectingMessages ? self.selectionScrollTop : nil
            }
            scrollView.wheelDidScroll = { [weak self] in
                guard let self else { return }
                let delta = self.selectionWheelTop.map { self.selectionScrollTop - $0 }
                self.selectionWheelTop = nil
                self.handlingWheel = false
                self.installIfPossible()
                self.reportViewport(reason: .user, userScrollDelta: delta)
            }
            tableView.headerView = nil
            // The column fills the viewport; automatic table styles add overflowing row padding.
            tableView.style = .plain
            tableView.addTableColumn(column)
            tableView.intercellSpacing = .zero
            tableView.selectionHighlightStyle = .none
            tableView.usesAutomaticRowHeights = false
            tableView.delegate = self
            tableView.dataSource = self
            scrollView.documentView = tableView
            // The clip view uses document coordinates, including the elastic area
            // before row zero. Keep this marker out of the fixed chrome and row layout.
            beginningLabel.font = .preferredFont(forTextStyle: .caption1)
            beginningLabel.textColor = .secondaryLabelColor
            beginningLabel.alignment = .center
            beginningLabel.stringValue = AppLanguage.localized("Beginning of conversation")
            beginningLabel.isHidden = true
            scrollView.contentView.addSubview(beginningLabel)
            view.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: view.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            displayScheduler = TimelineDisplayScheduler(view: view)
            // Scrolling must not replace a pending table/height transaction, or vice versa.
            scrollDisplayScheduler = TimelineDisplayScheduler(view: view)
            cancellable = model.updates.sink { [weak self] in self?.receive($0) }
            let notifications = NotificationCenter.default
            notifications.addObserver(
                self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
            notifications.addObserver(
                self, selector: #selector(userWillScroll),
                name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            notifications.addObserver(
                self, selector: #selector(userDidScroll),
                name: NSScrollView.didLiveScrollNotification, object: scrollView)
            notifications.addObserver(
                self, selector: #selector(userDidEndScroll),
                name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            notifications.addObserver(
                self, selector: #selector(backingPropertiesChanged(_:)),
                name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
            notifications.addObserver(
                self, selector: #selector(windowWillResize(_:)),
                name: NSWindow.willStartLiveResizeNotification, object: nil)
            notifications.addObserver(
                self, selector: #selector(windowDidResize(_:)),
                name: NSWindow.didEndLiveResizeNotification, object: nil)
            notifications.addObserver(
                self, selector: #selector(environmentChanged),
                name: NSLocale.currentLocaleDidChangeNotification, object: nil)
            notifications.addObserver(
                self, selector: #selector(environmentChanged), name: .NSSystemTimeZoneDidChange,
                object: nil)
        }

        private func applyConversationBackground() {
            let backgroundColor = NSColor(ChahuaTheme.conversationBackground(for: colorScheme))
            view.wantsLayer = true
            view.layer?.backgroundColor = backgroundColor.cgColor
            tableView.backgroundColor = backgroundColor
        }

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            voiceReporter.target = nil
            if model.selectionViewportSource === self { model.selectionViewportSource = nil }
            cancellable = nil
            displayScheduler?.cancel()
            displayScheduler = nil
            scrollDisplayScheduler?.cancel()
            scrollDisplayScheduler = nil
            stopScrolling()
            highlightTask?.cancel()
            highlightTask = nil
            contextSource.stop()
            NotificationCenter.default.removeObserver(self)
        }

        // Insets, native layout, synchronous notifications and scheduler.flush()
        // can all run inside a SwiftUI representable update. Keep physical table
        // work synchronous, but hand model changes off in their original FIFO order.
        private func enqueueModelChange(
            _ change: @escaping @MainActor (TimelineTableViewController) -> Void
        ) {
            guard !isTornDown else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                change(self)
            }
        }

        deinit {
            highlightTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        override func viewDidLayout() {
            guard !isTornDown else { return }
            contextSource.start()
            super.viewDidLayout()
            updateBeginningLabel()
            requestDisplayUpdate()
            if installedRevision < 0 { displayScheduler.flush() }
            reportViewport(reason: .layout)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            exactLayout(for: rows[row], allowingStaleOffscreen: true).size.height
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
            -> NSView?
        {
            let id = NSUserInterfaceItemIdentifier("timeline")
            let cell =
                tableView.makeView(withIdentifier: id, owner: self) as? TimelineTableCellView
                ?? TimelineTableCellView()
            cell.identifier = id
            let item = rows[row]
            bind(cell, row: item)
            return cell
        }

        func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int)
        {
            for cell in rowView.subviews.compactMap({ $0 as? TimelineTableCellView }) {
                cell.rowView.setVisible(false)
                guard let id = cell.rowView.binding?.presentation.row.id,
                    preparedRows[id] != nil
                else {
                    cell.clear()
                    continue
                }
            }
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            for cell in rowView.subviews.compactMap({ $0 as? TimelineTableCellView }) {
                cell.updateVisibility()
            }
            guard !applying, !exposedHeightChanges.isEmpty else { return }
            let position = capturePosition()
            applying = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                flushExposedHeightChanges()
                tableView.layoutSubtreeIfNeeded()
                restore(position)
            }
            settleExposedRows(preserving: position)
            settledPosition = capturePosition()
            applying = false
        }

        private func flushExposedHeightChanges() {
            guard !exposedHeightChanges.isEmpty else { return }
            let changed = exposedHeightChanges
            exposedHeightChanges.removeAll()
            tableView.noteHeightOfRows(withIndexesChanged: changed)
        }

        private func settleExposedRows(preserving position: Position) {
            guard needsFullHeightRefresh || !exposedHeightChanges.isEmpty else { return }
            while true {
                for index in heightRefreshIndexes {
                    let layout = exactLayout(for: rows[index])
                    liveResizeRows.insert(index)
                    if tableView.rect(ofRow: index).height != layout.size.height {
                        exposedHeightChanges.insert(index)
                    }
                }
                refreshVisibleRoots()
                guard !exposedHeightChanges.isEmpty else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    flushExposedHeightChanges()
                    tableView.layoutSubtreeIfNeeded()
                    if model.state.live.followsLatest && model.isAtLiveEdge {
                        setScrollOrigin(bottomOrigin)
                    } else {
                        restore(position)
                    }
                }
            }
        }

        private var currentEnvironment: TimelineLayoutEnvironment {
            let geometry = currentGeometry
            let key = EnvironmentKey(
                geometry: geometry, textSize: messageTextSize, language: appLanguage,
                showAllAvatars: showAllAvatars,
                showsMessageDetails: model.isGroupChat || showDmDetails,
                isWideChatLayout: isWideChatLayout,
                isSelectingMessages: actions.isSelectingMessages,
                direction: view.userInterfaceLayoutDirection == .rightToLeft
                    ? .rightToLeft : .leftToRight)
            if let cached = environmentCache, cached.key == key { return cached.value }
            // Scroll callbacks and their deferred viewport handoffs ask for the same
            // environment repeatedly. Resolve preferred fonts/locale only when its
            // inputs change, without delaying read or visible-media reporting.
            let bodySize = MessageTextSizePreference.scaledSize(
                messageTextSize, systemSize: geometry.fontSize, defaultSize: NSFont.systemFontSize)
            let environment = TimelineLayoutEnvironment.current(
                timelineWidth: max(
                    1,
                    geometry.rowWidth
                        - (actions.isSelectingMessages ? TimelineRowView.selectionGutterWidth : 0)),
                displayScale: geometry.scale,
                bodySize: bodySize,
                captionSize: MessageTextSizePreference.scaledSize(
                    messageTextSize,
                    systemSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                    defaultSize: 10),
                caption2Size: MessageTextSizePreference.scaledSize(
                    messageTextSize,
                    systemSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
                    defaultSize: 10),
                layoutDirection: key.direction, language: appLanguage,
                showAllAvatars: showAllAvatars,
                showsMessageDetails: key.showsMessageDetails,
                isWideChatLayout: isWideChatLayout)
            environmentCache = (key, environment)
            return environment
        }

        private func exactLayout(for row: TimelineRow, allowingStaleOffscreen: Bool = false)
            -> TimelineRowLayout
        {
            let environment = layoutEnvironment ?? currentEnvironment
            guard environment.timelineWidth.isFinite, environment.timelineWidth > 0 else {
                return preparedRows[row.id]?.layout ?? .empty
            }
            if let installed = preparedRows[row.id], installed.environment == environment,
                installed.row == row
            {
                return installed.layout
            }
            if allowingStaleOffscreen, needsFullHeightRefresh, let installed = preparedRows[row.id]
            {
                return installed.layout
            }
            let entry = rowCache.prepared(row, environment: environment)
            preparedRows[row.id] = entry
            return entry.layout
        }

        private func bind(_ cell: TimelineTableCellView, row: TimelineRow) {
            let oldHeight = preparedRows[row.id]?.layout.size.height
            let layout = exactLayout(for: row)
            if let oldHeight, oldHeight != layout.size.height,
                let index = rows.firstIndex(where: { $0.id == row.id })
            {
                exposedHeightChanges.insert(index)
            }
            guard let presentation = preparedRows[row.id]?.presentation else { return }
            cell.bind(
                .init(
                    presentation: presentation, layout: layout, context: rowContext(for: row),
                    actions: rowActions, mediaContext: mediaContext))
        }

        private func requestDisplayUpdate() {
            guard !isTornDown else { return }
            displayScheduler?.request { [weak self] in
                guard let self else { return }
                self.installIfPossible()
                if self.settlingHeights, self.settleNextHeightBatch() {
                    self.requestDisplayUpdate()
                }
            }
        }

        @objc private func environmentChanged() {
            environmentCache = nil
            preparation = nil
            requestDisplayUpdate()
        }

        private var currentGeometry: Geometry {
            let insets = scrollView.contentInsets
            return Geometry(
                size: scrollView.contentView.bounds.size,
                top: insets.top,
                left: insets.left,
                bottom: insets.bottom,
                right: insets.right,
                scale: view.window?.backingScaleFactor ?? 2,
                fontSize: NSFont.preferredFont(forTextStyle: .body).pointSize
            )
        }

        private func receive(_ snapshot: TimelineHostSnapshot) {
            updateBeginningLabel()
            // A subscriber can synchronously publish newer data before this subscriber
            // receives the older, outer send. Never replace installed or queued newer rows.
            let current = model.updates.value
            let newest = current.revision >= snapshot.revision ? current : snapshot
            guard newest.revision >= installedRevision,
                newest.revision >= (latestSnapshot?.revision ?? installedRevision)
            else { return }
            if let old = preparation,
                old.snapshot.revision != newest.revision
                    || old.snapshot.windowRevision != newest.windowRevision
            {
                let retained = Set(rows.map(\.id)).union(newest.rows.map(\.id))
                rowCache.remove(Set(old.snapshot.rows.map(\.id)).subtracting(retained))
                preparation = nil
            }
            latestSnapshot = newest
            requestDisplayUpdate()
            if installedRevision < 0 || newest.pendingScroll != nil { displayScheduler?.flush() }
        }

        private func installIfPossible() {
            guard !applying, displayScheduler != nil else { return }
            let environment = currentEnvironment
            guard environment.timelineWidth.isFinite, environment.timelineWidth > 0,
                currentGeometry.size.height > 0
            else { return }
            // Resize installed visible content before spending a bounded tick on a pending page.
            let deferredSnapshot =
                installedRevision >= 0 && layoutEnvironment != environment ? latestSnapshot : nil
            if deferredSnapshot != nil { latestSnapshot = nil }
            defer {
                if deferredSnapshot != nil {
                    if latestSnapshot == nil { latestSnapshot = model.updates.value }
                    requestDisplayUpdate()
                }
            }
            var prepared: TimelineLayoutPreparation?
            if let snapshot = latestSnapshot,
                snapshot.revision != installedRevision
                    || snapshot.windowRevision != installedWindowRevision
            {
                if preparation?.snapshot.revision != snapshot.revision
                    || preparation?.snapshot.windowRevision != snapshot.windowRevision
                    || preparation?.environment != environment
                {
                    preparation = TimelineLayoutPreparation(
                        snapshot: snapshot, environment: environment, cache: rowCache)
                }
                guard let work = preparation else { return }
                guard work.advance(cache: rowCache) else {
                    requestDisplayUpdate()
                    return
                }
                guard model.updates.value.revision == work.snapshot.revision,
                    model.updates.value.windowRevision == work.snapshot.windowRevision,
                    currentEnvironment == work.environment
                else {
                    preparation = nil
                    latestSnapshot = model.updates.value
                    requestDisplayUpdate()
                    return
                }
                prepared = work
                preparation = nil
            }
            applying = true
            var didWork = false
            while true {
                let geometry = currentGeometry
                let geometryChanged =
                    installedGeometry != geometry || layoutEnvironment != environment
                let heightsChanged = layoutEnvironment != environment
                let newlyVisibleResizeRows =
                    needsFullHeightRefresh
                    ? heightRefreshIndexes.subtracting(liveResizeRows) : IndexSet()
                if !newlyVisibleResizeRows.isEmpty { heightSettlementRevision = -1 }
                guard latestSnapshot != nil || geometryChanged || !newlyVisibleResizeRows.isEmpty
                else { break }
                let snapshot = latestSnapshot
                latestSnapshot = nil
                let dataChanged = prepared != nil
                let position =
                    geometryChanged ? settledPosition ?? capturePosition() : capturePosition()
                let layoutChanged =
                    dataChanged || geometryChanged || !newlyVisibleResizeRows.isEmpty
                if layoutChanged {
                    stopScrolling()
                    installedGeometry = geometry
                    layoutEnvironment = environment
                    measuredWidth = geometry.rowWidth
                    var changedHeights = exposedHeightChanges
                    exposedHeightChanges.removeAll()
                    if let work = prepared {
                        for (index, row) in work.snapshot.rows.enumerated() {
                            // Insertions are sized by the table update; only surviving rows resize.
                            guard let old = preparedRows[row.id], let new = work.rows[row.id],
                                old !== new, old.layout.size.height != new.layout.size.height
                            else { continue }
                            changedHeights.insert(index)
                        }
                        preparedRows = work.rows
                        needsFullHeightRefresh = false
                        settlingHeights = false
                        liveResizeRows.removeAll()
                    } else {
                        if heightsChanged {
                            needsFullHeightRefresh = !rows.isEmpty
                            settlingHeights = !rows.isEmpty
                            liveResizeRows.removeAll()
                            heightSettlementRevision = -1
                            nextHeightSettlementRow = 0
                        }
                        for index in heightRefreshIndexes
                        where heightsChanged
                            || !liveResizeRows.contains(index) && needsFullHeightRefresh
                        {
                            let oldHeight = preparedRows[rows[index].id]?.layout.size.height
                            let layout = exactLayout(for: rows[index])
                            liveResizeRows.insert(index)
                            if oldHeight != layout.size.height { changedHeights.insert(index) }
                        }
                    }
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0
                        context.allowsImplicitAnimation = false
                        column.width = measuredWidth
                        if let snapshot, dataChanged {
                            installRows(snapshot, changedHeights: changedHeights)
                        } else if !changedHeights.isEmpty {
                            tableView.noteHeightOfRows(withIndexesChanged: changedHeights)
                        }
                        refreshVisibleRoots()
                        flushExposedHeightChanges()
                        tableView.layoutSubtreeIfNeeded()
                        scrollView.layoutSubtreeIfNeeded()
                    }
                    if settlingHeights { requestDisplayUpdate() }
                }

                let current = model.updates.value
                if activeRequest?.id != current.pendingScroll?.id {
                    stopScrolling()
                    activeRequest = nil
                }
                // A reentrant publication may have replaced the data while AppKit laid out.
                // Its request belongs to the next transaction, not the rows just installed.
                if installedRevision == current.revision {
                    if let request = current.pendingScroll {
                        if request.id != lastStartedRequestID {
                            stopScrolling()
                            activeRequest = request
                            lastStartedRequestID = request.id
                            execute(request, beginHighlight: true)
                        } else if activeRequest?.id == request.id, layoutChanged {
                            execute(request, beginHighlight: false)
                        }
                    } else if layoutChanged {
                        if model.state.live.followsLatest && model.isAtLiveEdge {
                            scroll(
                                to: bottomOrigin,
                                animated: !geometryChanged && snapshot?.animateFollowing == true,
                                requestID: nil)
                        } else {
                            restore(position)
                        }
                    }
                }
                settleExposedRows(preserving: capturePosition())
                if scrollAnimation == nil { settledPosition = capturePosition() }
                didWork = true
                if latestSnapshot != nil { requestDisplayUpdate() }
                break
            }

            applying = false
            if didWork { reportViewport(reason: .programmatic) }
        }

        private func installRows(_ snapshot: TimelineHostSnapshot, changedHeights: IndexSet) {
            let oldIDs = Set(rows.map(\.id))
            let newIDs = Set(snapshot.rows.map(\.id))
            let reset = installedRevision < 0 || installedWindowRevision != snapshot.windowRevision
            let change =
                reset ? TimelineChange.reset : TimelineChange.compute(from: rows, to: snapshot.rows)
            rowCache.remove(oldIDs.subtracting(newIDs))
            switch change {
            case .reset:
                rows = snapshot.rows
                tableView.reloadData()
            case .incremental(let removals, let insertions, let reloads):
                if !removals.isEmpty || !insertions.isEmpty {
                    tableView.beginUpdates()
                    rows = snapshot.rows
                    tableView.removeRows(at: removals, withAnimation: [])
                    tableView.insertRows(at: insertions, withAnimation: [])
                    tableView.endUpdates()
                } else {
                    rows = snapshot.rows
                }
                for index in reloads {
                    guard
                        let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
                            as? TimelineTableCellView
                    else { continue }
                    bind(cell, row: rows[index])
                }
                let changedHeights = changedHeights.subtracting(insertions)
                if !changedHeights.isEmpty {
                    if liveResizing { liveResizeRows.formUnion(changedHeights) }
                    tableView.noteHeightOfRows(withIndexesChanged: changedHeights)
                }
            }
            installedRevision = snapshot.revision
            installedWindowRevision = snapshot.windowRevision
        }

        private var unobscuredDocumentRect: NSRect {
            documentViewport(topInset: unobscuredHeaderInset)
        }

        private func documentViewport(topInset: CGFloat) -> NSRect {
            let visible = scrollView.documentVisibleRect
            let insets = scrollView.contentInsets
            return NSRect(
                x: visible.minX + insets.left,
                y: visible.minY + topInset,
                width: max(0, visible.width - insets.left - insets.right),
                height: max(0, visible.height - topInset - insets.bottom))
        }

        private func capturePosition() -> Position {
            let visible = documentViewport(topInset: scrollView.contentInsets.top)
            let anchorY = visible.minY
            let range = tableView.rows(in: visible)
            if range.location != NSNotFound, range.length > 0 {
                let upperBound = min(NSMaxRange(range), rows.count)
                if range.location < upperBound,
                    let index = (range.location..<upperBound).first(where: {
                        if case .message = rows[$0] { return true }
                        return false
                    })
                {
                    return Position(
                        messageID: rows[index].id,
                        offset: tableView.rect(ofRow: index).minY - anchorY,
                        originY: anchorY)
                }
            }
            return Position(messageID: nil, offset: 0, originY: anchorY)
        }

        private func restore(_ position: Position) {
            let y: CGFloat
            if let id = position.messageID, let index = rows.firstIndex(where: { $0.id == id }) {
                y = tableView.rect(ofRow: index).minY - position.offset
            } else {
                // The anchor may have been deleted or replaced with another history window.
                y = position.originY
            }
            setScrollOrigin(constrainedOrigin(y: y - scrollView.contentInsets.top))
        }

        private var bottomOrigin: NSPoint {
            constrainedOrigin(
                y: max(
                    -scrollView.contentInsets.top,
                    tableView.bounds.maxY - scrollView.contentView.bounds.height
                        + scrollView.contentInsets.bottom))
        }

        private func constrainedOrigin(y: CGFloat) -> NSPoint {
            var bounds = scrollView.contentView.bounds
            bounds.origin = NSPoint(x: -scrollView.contentInsets.left, y: y)
            return scrollView.contentView.constrainBoundsRect(bounds).origin
        }

        private func setScrollOrigin(_ origin: NSPoint) {
            settingScrollOrigin = true
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            settingScrollOrigin = false
        }

        private func execute(_ request: TimelineScrollRequest, beginHighlight: Bool) {
            switch request.intent {
            case .bottom(let animated):
                if let index = rows.indices.last { prepareScrollTarget(index) }
                scroll(to: bottomOrigin, animated: animated, requestID: request.id)
            case .reveal(let id, let animated, _), .reaction(let id, let animated, _),
                .readBoundary(let id, let animated):
                guard let index = rows.firstIndex(where: { $0.id == id }) else {
                    finishRequest(id: request.id)
                    return
                }
                prepareScrollTarget(index)
                if beginHighlight {
                    switch request.intent {
                    case .reveal(_, _, true), .reaction(_, _, true):
                        highlightRow(id)
                    default:
                        break
                    }
                }
                let frame = tableView.rect(ofRow: index)
                let target: NSPoint
                if case .readBoundary = request.intent {
                    target = constrainedOrigin(
                        y: frame.maxY - scrollView.contentView.bounds.height
                            + scrollView.contentInsets.bottom)
                } else if case .reaction = request.intent {
                    let region = preparedRows[id]?.layout.reactionRegion(in: frame) ?? frame
                    target = constrainedOrigin(
                        y: region.midY - unobscuredHeaderInset
                            - unobscuredDocumentRect.height / 2)
                } else {
                    target = constrainedOrigin(
                        y: id == .unreadSeparator
                            ? frame.minY - unobscuredHeaderInset
                            : frame.midY - unobscuredHeaderInset
                                - unobscuredDocumentRect.height / 2)
                }
                scroll(to: target, animated: animated, requestID: request.id)
            }
        }

        private func prepareScrollTarget(_ index: Int) {
            let layout = exactLayout(for: rows[index])
            liveResizeRows.insert(index)
            guard tableView.rect(ofRow: index).height != layout.size.height else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
                tableView.layoutSubtreeIfNeeded()
            }
        }

        private func scroll(to target: NSPoint, animated: Bool, requestID: Int?) {
            stopScrolling()
            let start = scrollView.contentView.bounds.origin
            guard animated, abs(start.y - target.y) > 0.5 || abs(start.x - target.x) > 0.5 else {
                setScrollOrigin(target)
                settleExposedRows(preserving: capturePosition())
                if let requestID { finishRequest(id: requestID) }
                return
            }
            let animation = ScrollAnimation(
                start: start, target: target, startedAt: ProcessInfo.processInfo.systemUptime,
                generation: scrollGeneration, requestID: requestID)
            scrollAnimation = animation
            scheduleScrollFrame(animation)
        }

        private func scheduleScrollFrame(_ animation: ScrollAnimation) {
            // Follow the view's actual display cadence instead of waking every 16 ms
            // between refreshes. Elapsed time still owns duration and cancellation
            // fences every physical write, including reentrant snapshot installation.
            scrollDisplayScheduler?.request { [weak self] in
                guard let self, self.scrollGeneration == animation.generation else { return }
                self.installIfPossible()
                guard self.scrollGeneration == animation.generation else { return }
                let progress = CGFloat(
                    min(1, (ProcessInfo.processInfo.systemUptime - animation.startedAt) / 0.25))
                let eased = progress * progress * (3 - 2 * progress)
                self.setScrollOrigin(
                    NSPoint(
                        x: animation.start.x + (animation.target.x - animation.start.x) * eased,
                        y: animation.start.y + (animation.target.y - animation.start.y) * eased))
                guard self.scrollGeneration == animation.generation else { return }
                if progress >= 1 {
                    self.scrollAnimation = nil
                    self.applying = true
                    self.settleExposedRows(preserving: self.capturePosition())
                    self.applying = false
                    if let requestID = animation.requestID { self.finishRequest(id: requestID) }
                    self.installIfPossible()
                    self.reportViewport(reason: .programmatic)
                } else {
                    self.scheduleScrollFrame(animation)
                }
            }
        }

        private func stopScrolling() {
            scrollGeneration &+= 1
            scrollAnimation = nil
            scrollDisplayScheduler?.cancel()
        }

        private func finishRequest(id: Int) {
            guard activeRequest?.id == id, installedRevision == model.updates.value.revision else {
                return
            }
            activeRequest = nil
            enqueueModelChange { host in host.model.scrollRequestDidFinish(id: id) }
        }

        private func highlightRow(_ id: TimelineRowID) {
            let previousID = highlightedRowID
            highlightedRowID = id
            if let previousID { refreshHighlight(previousID) }
            refreshHighlight(id)
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                guard let self, self.highlightedRowID == id else { return }
                self.highlightedRowID = nil
                self.refreshHighlight(id)
            }
        }

        private func refreshHighlight(_ id: TimelineRowID) {
            guard let index = rows.firstIndex(where: { $0.id == id }),
                let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
                    as? TimelineTableCellView
            else { return }
            bind(cell, row: rows[index])
        }

        private var heightRefreshIndexes: IndexSet {
            let visible = tableView.rows(in: scrollView.documentVisibleRect)
            guard visible.location != NSNotFound else { return [] }
            return IndexSet(
                integersIn: max(0, visible.location)..<min(NSMaxRange(visible), rows.count))
        }

        @objc private func windowWillResize(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, window === view.window else {
                return
            }
            windowLiveResizing = true
            cancelHeightSettlement()
        }

        @objc private func windowDidResize(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, window === view.window else {
                return
            }
            windowLiveResizing = false
            finishResizeIfPossible()
        }

        private func finishResizeIfPossible() {
            guard !windowLiveResizing, !isSplitResizing else { return }
            settlingHeights = needsFullHeightRefresh
            heightSettlementRevision = -1
            requestDisplayUpdate()
        }

        private func cancelHeightSettlement() {
            heightSettlementRevision = -1
        }

        private func settleNextHeightBatch() -> Bool {
            guard !applying else { return true }
            guard settlingHeights, latestSnapshot == nil, preparation == nil,
                layoutEnvironment == currentEnvironment
            else { return false }
            // Do not repeatedly interrupt an owned scroll animation with corrections.
            guard scrollAnimation == nil else { return true }
            if heightSettlementRevision != installedRevision
                || heightSettlementGeometry != installedGeometry
            {
                heightSettlementRevision = installedRevision
                heightSettlementGeometry = installedGeometry
                nextHeightSettlementRow = 0
                let visible = scrollView.documentVisibleRect
                let range = tableView.rows(in: visible.insetBy(dx: 0, dy: -visible.height))
                let priority =
                    range.location == NSNotFound
                    ? IndexSet()
                    : IndexSet(
                        integersIn: max(0, range.location)..<min(NSMaxRange(range), rows.count))
                heightSettlementOrder =
                    Array(priority) + rows.indices.filter { !priority.contains($0) }
                heightSettlementPriorityCount = priority.count
            }
            let position = capturePosition()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.004
            let settlementEnd =
                windowLiveResizing || isSplitResizing
                ? heightSettlementPriorityCount : heightSettlementOrder.count
            let upperBound = min(settlementEnd, nextHeightSettlementRow + 32)
            guard nextHeightSettlementRow < settlementEnd else { return false }
            var changed = IndexSet()
            applying = true
            while nextHeightSettlementRow < upperBound {
                let index = heightSettlementOrder[nextHeightSettlementRow]
                nextHeightSettlementRow += 1
                if !liveResizeRows.contains(index) {
                    let previousHeight = preparedRows[rows[index].id]?.layout.size.height
                    let height = exactLayout(for: rows[index]).size.height
                    liveResizeRows.insert(index)
                    if previousHeight != height { changed.insert(index) }
                }
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
            }
            if !changed.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    tableView.noteHeightOfRows(withIndexesChanged: changed)
                    tableView.layoutSubtreeIfNeeded()
                    flushExposedHeightChanges()
                    scrollView.layoutSubtreeIfNeeded()
                    if model.state.live.followsLatest && model.isAtLiveEdge {
                        setScrollOrigin(bottomOrigin)
                    } else {
                        restore(position)
                    }
                }
            }
            settleExposedRows(preserving: position)
            settledPosition = capturePosition()
            applying = false
            // Data/geometry can publish reentrantly during native layout. Drain it
            // before deciding this pass has settled the current revision and width.
            if latestSnapshot != nil { requestDisplayUpdate() }
            if windowLiveResizing || isSplitResizing,
                nextHeightSettlementRow >= heightSettlementPriorityCount
            {
                return false
            }
            if nextHeightSettlementRow < heightSettlementOrder.count
                || heightSettlementRevision != installedRevision
                || heightSettlementGeometry != installedGeometry
            {
                return true
            }
            needsFullHeightRefresh = false
            settlingHeights = false
            liveResizeRows.removeAll()
            reportViewport(reason: .layout)
            return false
        }

        private func makeRowActions() -> TimelineBubbleActions {
            .init(
                openMedia: actions.openMedia == nil
                    ? nil : { [weak self] in self?.actions.openMedia?($0) },
                openSticker: actions.openSticker == nil
                    ? nil : { [weak self] in self?.actions.openSticker?($0) },
                openReply: actions.openReply == nil
                    ? nil : { [weak self] in self?.actions.openReply?($0) },
                openSystemMessage: actions.openSystemMessage == nil
                    ? nil : { [weak self] in self?.actions.openSystemMessage?($0) },
                openReactionDetails: actions.openReactionDetails == nil
                    ? nil : { [weak self] in self?.actions.openReactionDetails?($0) },
                replyToMessage: actions.replyToMessage == nil
                    ? nil : { [weak self] in self?.actions.replyToMessage?($0) },
                editMessage: actions.editMessage == nil
                    ? nil : { [weak self] in self?.actions.editMessage?($0) },
                deleteMessage: actions.deleteMessage == nil
                    ? nil : { [weak self] in self?.actions.deleteMessage?($0) },
                openThread: actions.openThread == nil
                    ? nil : { [weak self] in self?.actions.openThread?($0) },
                openLink: actions.openLink == nil
                    ? nil : { [weak self] in self?.actions.openLink?($0) },
                openMention: actions.openMention == nil
                    ? nil : { [weak self] in self?.actions.openMention?($0) },
                openFailedMessage: actions.openFailedMessage == nil
                    ? nil : { [weak self] in self?.actions.openFailedMessage?($0) },
                openContextMenu: actions.openContextMenu == nil || actions.isSelectingMessages
                    || actions.interactionContext.isReadOnly
                    ? nil : { [weak self] in self?.actions.openContextMenu?($0, $1) },
                toggleReaction: actions.toggleReaction == nil
                    ? nil : { [weak self] in self?.actions.toggleReaction?($0, $1) },
                pendingReactionMessageIDs: actions.pendingReactionMessageIDs,
                interactionContext: actions.interactionContext,
                editablePendingMessageIDs: actions.editablePendingMessageIDs,
                removablePendingMessageIDs: actions.removablePendingMessageIDs,
                editPendingMessage: actions.editPendingMessage == nil
                    ? nil : { [weak self] in self?.actions.editPendingMessage?($0) },
                removePendingMessage: actions.removePendingMessage == nil
                    ? nil : { [weak self] in self?.actions.removePendingMessage?($0) },
                isSelectingMessages: actions.isSelectingMessages,
                selectedMessageIDs: actions.selectedMessageIDs,
                toggleMessageSelection: actions.toggleMessageSelection == nil
                    ? nil : { [weak self] in self?.actions.toggleMessageSelection?($0) },
                endMessageSelection: actions.endMessageSelection == nil
                    ? nil : { [weak self] in self?.actions.endMessageSelection?() },
                forwardMessage: actions.forwardMessage == nil
                    ? nil : { [weak self] in self?.actions.forwardMessage?($0) },
                openForwardedMessages: actions.openForwardedMessages == nil
                    ? nil : { [weak self] in self?.actions.openForwardedMessages?($0) },
                isSelectionBusy: actions.isSelectionBusy,
                selectionMessages: actions.selectionMessages,
                removeSelectedMessage: actions.removeSelectedMessage == nil
                    ? nil : { [weak self] in self?.actions.removeSelectedMessage?($0) },
                openAttachment: actions.openAttachment == nil
                    ? nil : { [weak self] in self?.actions.openAttachment?($0) }
            )
        }

        private func rowContext(for row: TimelineRow) -> TimelineRowContext {
            .init(
                isHighlighted: row.id == highlightedRowID,
                currentUserID: model.currentUserID,
                isThreadTimeline: model.threadID != nil
            )
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            isDisappearing = false
            reportVoiceViewport()
            contextSource.start()
            updateVisibleMedia()
        }

        override func viewDidDisappear() {
            super.viewDidDisappear()
            isDisappearing = true
            voiceReporter.report(false)
            contextSource.stop()
            tableView.enumerateAvailableRowViews { row, _ in
                for cell in row.subviews.compactMap({ $0 as? TimelineTableCellView }) {
                    cell.rowView.setVisible(false)
                }
            }
        }

        private func updateVisibleMedia() {
            tableView.enumerateAvailableRowViews { row, _ in
                for cell in row.subviews.compactMap({ $0 as? TimelineTableCellView }) {
                    cell.updateVisibility()
                }
            }
        }

        private func refreshVisibleRoots() {
            let visible = tableView.rows(in: scrollView.documentVisibleRect)
            guard visible.location != NSNotFound else { return }
            for index in visible.location..<min(NSMaxRange(visible), rows.count) {
                guard
                    let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
                        as? TimelineTableCellView
                else { continue }
                bind(cell, row: rows[index])
            }
        }

        private func updateBeginningLabel() {
            let clip = scrollView.contentView
            let height =
                tableView.numberOfRows > 0
                ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY : 0
            let restingTop = min(
                -scrollView.contentInsets.top,
                height - clip.bounds.height + scrollView.contentInsets.bottom)
            beginningLabel.isHidden =
                !model.state.olderBoundaryIsKnownStart || model.state.older != .idle
                || tableView.numberOfRows == 0 || clip.bounds.minY >= restingTop
            beginningLabel.frame = NSRect(x: 0, y: -48, width: clip.bounds.width, height: 48)
        }

        @objc private func boundsChanged() {
            updateBeginningLabel()
            guard !applying, !settingScrollOrigin, !handlingWheel else { return }
            // Bounds notifications arrive inside AppKit's inset/resize transaction.
            // Place messages after layout, otherwise that transaction can overwrite
            // the initial bottom position with its own top-inset adjustment.
            guard installedGeometry == currentGeometry else {
                view.needsLayout = true
                return
            }
            installIfPossible()
            if !liveScrolling { reportViewport(reason: .layout) }
        }

        @objc private func backingPropertiesChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, window === view.window else {
                return
            }
            installIfPossible()
        }

        private func cancelForUserScroll() {
            stopScrolling()
            activeRequest = nil
            settledPosition = capturePosition()
            enqueueModelChange { host in host.model.userScrollBegan() }
        }

        @objc private func userWillScroll() {
            liveScrolling = true
            cancelForUserScroll()
        }

        @objc private func userDidScroll() {
            guard !applying, !settingScrollOrigin, !handlingWheel else { return }
            // Scrollbar drags and phase-less wheels may arrive without a will-start event.
            cancelForUserScroll()
            installIfPossible()
            reportViewport(reason: .user)
        }

        @objc private func userDidEndScroll() {
            liveScrolling = false
            installIfPossible()
            reportViewport(reason: .user)
        }

        private var hasCurrentViewport: Bool {
            !isTornDown && !applying && !settingScrollOrigin && !handlingWheel
                && scrollAnimation == nil
                && latestSnapshot == nil && installedRevision >= 0
                && installedRevision == model.updates.value.revision
                && installedGeometry == currentGeometry && layoutEnvironment == currentEnvironment
        }

        private func visibleRows(in rect: NSRect) -> Range<Int> {
            guard !rect.isEmpty else { return 0..<0 }
            let range = tableView.rows(in: rect)
            guard range.location != NSNotFound, range.length > 0, range.location < rows.count
            else { return 0..<0 }
            return range.location..<min(NSMaxRange(range), rows.count)
        }

        func visibleMessageIDsForSelection() -> [MessageID]? {
            let viewport = unobscuredDocumentRect
            guard hasCurrentViewport, view.window != nil, !viewport.isEmpty else { return nil }
            return visibleRows(in: viewport).compactMap { index in
                guard viewport.intersects(tableView.rect(ofRow: index)) else { return nil }
                return rows[index].messageID
            }
        }

        private var selectionScrollTop: CGFloat {
            let viewport = unobscuredDocumentRect
            return min(max(0, tableView.bounds.maxY - viewport.height), max(0, viewport.minY))
        }

        func configureVoiceViewport(_ target: VoiceTimelineTarget?, headerInset: CGFloat?) {
            let changed = voiceReporter.target != target
            guard changed || voiceReferenceHeaderInset != headerInset else { return }
            voiceReferenceHeaderInset = headerInset
            voiceReporter.target = target
            if changed, target != nil, isViewLoaded { refreshVisibleRoots() }
            reportVoiceViewport()
        }

        func reportVoiceViewport() {
            guard voiceReporter.target != nil else { return }
            guard isViewLoaded, !isDisappearing, !isTornDown, !view.isHiddenOrHasHiddenAncestor,
                let window = view.window, window.occlusionState.contains(.visible)
            else {
                voiceReporter.report(false)
                return
            }
            guard !applying else { return }
            guard
                let index = voiceReporter.rowIndex(
                    in: rows, chatID: model.chatID, revision: installedRevision),
                let region = preparedRows[rows[index].id]?.layout.voiceRegion(
                    in: tableView.rect(ofRow: index))
            else {
                voiceReporter.report(false)
                return
            }
            var viewport = unobscuredDocumentRect
            if let inset = voiceReferenceHeaderInset {
                viewport = VoiceTimelineVisibility.referenceViewport(
                    viewport, scrollTop: scrollView.documentVisibleRect.minY,
                    bottomLimit: tableView.bounds.maxY - scrollView.contentView.bounds.height
                        + scrollView.contentInsets.bottom, headerInset: inset)
            }
            voiceReporter.report(region: region, in: viewport)
        }

        private func reportViewport(
            reason: TimelineViewportChangeReason, userScrollDelta: CGFloat? = nil
        ) {
            updateVisibleMedia()
            reportVoiceViewport()
            guard hasCurrentViewport, !liveScrolling || reason == .user else { return }
            // Rendering and height preparation retain the full document viewport
            // for the blur. Read, jump, paging and visible-media candidates use
            // only the area between the floating header/pins and composer.
            let unobscured = unobscuredDocumentRect
            // A fully covered viewport must cancel the previous read candidate,
            // not leave its dwell timer running while there is no usable area.
            let range = visibleRows(in: unobscured)
            var visibleMessageIDs: [MessageID] = []
            var visibleReactionMessageIDs: [MessageID] = []
            for index in range {
                let frame = tableView.rect(ofRow: index)
                guard let id = rows[index].messageID, unobscured.intersects(frame) else { continue }
                visibleMessageIDs.append(id)
                if let region = preparedRows[rows[index].id]?.layout.reactionRegion(in: frame) {
                    let intersection = region.intersection(unobscured)
                    if intersection.width > 0 && intersection.height > 0 {
                        visibleReactionMessageIDs.append(id)
                    }
                }
            }
            settledPosition = capturePosition()
            let maxTop = max(0, tableView.bounds.maxY - unobscured.height)
            let top = min(maxTop, max(0, unobscured.minY))
            let viewport = TimelineViewport(
                firstVisibleIndex: range.first,
                lastVisibleIndex: range.last,
                distanceToTop: top,
                distanceToBottom: maxTop - top,
                height: unobscured.height,
                visibleMessageIDs: visibleMessageIDs,
                visibleReactionMessageIDs: visibleReactionMessageIDs,
                userScrollDelta: userScrollDelta)
            let revision = installedRevision
            let geometry = installedGeometry
            let environment = layoutEnvironment
            enqueueModelChange { host in
                // A new snapshot/resize can supersede a measured native viewport
                // before the handoff; never publish its old indices or geometry.
                guard host.installedRevision == revision,
                    host.model.updates.value.revision == revision,
                    host.currentGeometry == geometry,
                    host.currentEnvironment == environment
                else { return }
                host.model.viewportDidChange(viewport, reason: reason, revision: revision)
            }
        }
    }
#endif
