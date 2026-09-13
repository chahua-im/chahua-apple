#if os(macOS)
import AppKit
import ChahuaAPI
import Combine
import SwiftUI

// SwiftUI receives cursor updates at the row host even when it forwards clicks
// into a represented NSTextView. Route text-region updates to AppKit as well:
// it already owns link hit testing and selection, which SwiftUI cannot reproduce.
@MainActor
final class TimelineBubbleHostingView<Content: View>: NSHostingView<Content> {
    // Swift 6.3.2's Release EarlyPerfInliner crashes on this generic
    // NSHostingView subclass's synthesized deinit; an explicit body avoids it.
    deinit {}

    override func cursorUpdate(with event: NSEvent) {
        if let text = textView(at: event.locationInWindow, in: self) {
            text.cursorUpdate(with: event)
        } else {
            super.cursorUpdate(with: event)
        }
    }

    private func textView(at point: NSPoint, in view: NSView) -> AppKitMessageTextView? {
        guard !view.isHidden else { return nil }
        if let text = view as? AppKitMessageTextView {
            let local = text.convert(point, from: nil)
            guard text.bounds.contains(local), text.visibleRect.contains(local),
                  let parent = text.superview,
                  text.hitTest(parent.convert(point, from: nil)) === text else { return nil }
            return text
        }
        for child in view.subviews.reversed() {
            if let text = textView(at: point, in: child) { return text }
        }
        return nil
    }
}

@MainActor
final class TimelineTableCellView: NSTableCellView {
    let state = TimelineRowHostState()
    lazy var hosting = TimelineBubbleHostingView(rootView: TimelineRowHostView(state: state))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The table supplies exact row geometry. Intrinsic/minimum-size probes
        // otherwise rewrap every bubble at unrelated widths during live resize.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

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

@MainActor
final class TimelineTableViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
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

    private struct Position {
        let messageID: TimelineRowID?
        let offset: CGFloat
        let originY: CGFloat
    }

    private let model: ConversationTimelineModel
    private var rows: [TimelineRow] = []
    var actions = TimelineBubbleActions() {
        didSet {
            guard !actions.hasSameRendering(as: oldValue) else { return }
            rowActions = makeRowActions()
            guard isViewLoaded else { return }
            if actions.currentUserProfile != oldValue.currentUserProfile {
                latestSnapshot = model.updates.value
                profileNeedsPreparation = true
                preparation = nil
                requestDisplayUpdate()
            }
            refreshVisibleRoots()
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
    var headerInset: CGFloat = 0 {
        didSet {
            guard headerInset != oldValue, isViewLoaded else { return }
            scrollView.contentInsets.top = headerInset
            view.needsLayout = true
        }
    }
    var composerInset: CGFloat = 0 {
        didSet {
            guard composerInset != oldValue, isViewLoaded else { return }
            scrollView.contentInsets.bottom = composerInset
            view.needsLayout = true
        }
    }
    private let layoutCache = TimelineLayoutCache()
    private var presentations: [TimelineRowID: TimelineRowPresentation] = [:]
    private var installedLayouts: [TimelineRowID: TimelineRowLayout] = [:]
    private var preparation: TimelineLayoutPreparation?
    private var layoutEnvironment: TimelineLayoutEnvironment?
    private var displayScheduler: TimelineDisplayScheduler!
    private var profileNeedsPreparation = false
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
    private var liveScrolling = false
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
    private var scrollTask: Task<Void, Never>?
    private var scrollGeneration = 0
    private let scrollView = TimelineScrollView()
    private let tableView = NSTableView()
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
        applyConversationBackground()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // AppKit already insets the scroller by contentInsets. Setting
        // scrollerInsets too would count the header and composer padding twice.
        scrollView.contentInsets.top = headerInset
        scrollView.contentInsets.bottom = composerInset
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.wheelWillScroll = { [weak self] in
            guard let self else { return }
            self.handlingWheel = true
            self.cancelForUserScroll()
        }
        scrollView.wheelDidScroll = { [weak self] in
            guard let self else { return }
            self.handlingWheel = false
            self.installIfPossible()
            self.reportViewport(reason: .user)
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
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        displayScheduler = TimelineDisplayScheduler(view: view)
        cancellable = model.updates.sink { [weak self] in self?.receive($0) }
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        notifications.addObserver(self, selector: #selector(userWillScroll), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        notifications.addObserver(self, selector: #selector(userDidScroll), name: NSScrollView.didLiveScrollNotification, object: scrollView)
        notifications.addObserver(self, selector: #selector(userDidEndScroll), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        notifications.addObserver(self, selector: #selector(backingPropertiesChanged(_:)), name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
        notifications.addObserver(self, selector: #selector(windowWillResize(_:)), name: NSWindow.willStartLiveResizeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(windowDidResize(_:)), name: NSWindow.didEndLiveResizeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(environmentChanged), name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(environmentChanged), name: .NSSystemTimeZoneDidChange, object: nil)
    }

    private func applyConversationBackground() {
        let backgroundColor = NSColor(ChahuaTheme.conversationBackground(for: colorScheme))
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.cgColor
        tableView.backgroundColor = backgroundColor
    }

    deinit {
        scrollTask?.cancel()
        highlightTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        requestDisplayUpdate()
        if installedRevision < 0 { displayScheduler.flush() }
        reportViewport(reason: .layout)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        exactLayout(for: rows[row], allowingStaleOffscreen: true).size.height
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("timeline")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TimelineTableCellView ?? TimelineTableCellView()
        cell.identifier = id
        let item = rows[row]
        bind(cell, row: item)
        return cell
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        for cell in rowView.subviews.compactMap({ $0 as? TimelineTableCellView }) { cell.state.clear() }
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
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
                if tableView.rect(ofRow: index).height != layout.size.height { exposedHeightChanges.insert(index) }
            }
            refreshVisibleRoots()
            guard !exposedHeightChanges.isEmpty else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                flushExposedHeightChanges()
                tableView.layoutSubtreeIfNeeded()
                if model.state.live.followsLatest && model.isAtLiveEdge { setScrollOrigin(bottomOrigin) }
                else { restore(position) }
            }
        }
    }

    private var currentEnvironment: TimelineLayoutEnvironment {
        .current(timelineWidth: currentGeometry.rowWidth,
                 displayScale: currentGeometry.scale,
                 bodySize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                 captionSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                 caption2Size: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
                 layoutDirection: view.userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    private func exactLayout(for row: TimelineRow, allowingStaleOffscreen: Bool = false) -> TimelineRowLayout {
        let environment = layoutEnvironment ?? currentEnvironment
        guard environment.timelineWidth.isFinite, environment.timelineWidth > 0 else {
            return installedLayouts[row.id] ?? .empty
        }
        if let presentation = presentations[row.id], presentation.environment == environment,
           presentation.row == row, let layout = installedLayouts[row.id] { return layout }
        if allowingStaleOffscreen, needsFullHeightRefresh, let layout = installedLayouts[row.id] { return layout }
        let presentation = TimelineRowPresentation.make(row: row, currentUserProfile: actions.currentUserProfile, currentUserID: model.currentUserID, isThreadTimeline: model.threadID != nil, environment: environment)
        let layout = layoutCache.layout(for: presentation, environment: environment)
        presentations[row.id] = presentation
        installedLayouts[row.id] = layout
        return layout
    }

    private func bind(_ cell: TimelineTableCellView, row: TimelineRow) {
        let oldHeight = installedLayouts[row.id]?.size.height
        let layout = exactLayout(for: row)
        if let oldHeight, oldHeight != layout.size.height, let index = rows.firstIndex(where: { $0.id == row.id }) {
            exposedHeightChanges.insert(index)
        }
        guard let presentation = presentations[row.id] else { return }
        cell.state.bind(.init(presentation: presentation, layout: layout, context: rowContext(for: row), actions: rowActions, mediaContext: mediaContext))
    }

    private func requestDisplayUpdate() {
        displayScheduler?.request { [weak self] in
            guard let self else { return }
            self.installIfPossible()
            if self.settlingHeights, self.settleNextHeightBatch() { self.requestDisplayUpdate() }
        }
    }

    @objc private func environmentChanged() {
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
        // A subscriber can synchronously publish newer data before this subscriber
        // receives the older, outer send. Never replace installed or queued newer rows.
        let current = model.updates.value
        let newest = current.revision >= snapshot.revision ? current : snapshot
        guard newest.revision >= installedRevision,
              newest.revision >= (latestSnapshot?.revision ?? installedRevision) else { return }
        if let old = preparation, old.snapshot.revision != newest.revision || old.snapshot.windowRevision != newest.windowRevision {
            let retained = Set(rows.map(\.id)).union(newest.rows.map(\.id))
            layoutCache.remove(Set(old.snapshot.rows.map(\.id)).subtracting(retained))
            preparation = nil
        }
        latestSnapshot = newest
        requestDisplayUpdate()
        if installedRevision < 0 || newest.pendingScroll != nil { displayScheduler?.flush() }
    }

    private func installIfPossible() {
        guard !applying, displayScheduler != nil else { return }
        let environment = currentEnvironment
        guard environment.timelineWidth.isFinite, environment.timelineWidth > 0, currentGeometry.size.height > 0 else { return }
        // Resize installed visible content before spending a bounded tick on a pending page.
        let deferredSnapshot = installedRevision >= 0 && layoutEnvironment != environment ? latestSnapshot : nil
        if deferredSnapshot != nil { latestSnapshot = nil }
        defer {
            if deferredSnapshot != nil {
                if latestSnapshot == nil { latestSnapshot = model.updates.value }
                requestDisplayUpdate()
            }
        }
        var prepared: TimelineLayoutPreparation?
        if let snapshot = latestSnapshot,
           snapshot.revision != installedRevision || snapshot.windowRevision != installedWindowRevision
                || profileNeedsPreparation {
            if preparation?.snapshot.revision != snapshot.revision
                || preparation?.snapshot.windowRevision != snapshot.windowRevision
                || preparation?.environment != environment || preparation?.profile != actions.currentUserProfile {
                preparation = TimelineLayoutPreparation(snapshot: snapshot, environment: environment, profile: actions.currentUserProfile)
            }
            guard let work = preparation else { return }
            guard work.advance(cache: layoutCache, currentUserID: model.currentUserID, isThreadTimeline: model.threadID != nil) else {
                requestDisplayUpdate()
                return
            }
            guard model.updates.value.revision == work.snapshot.revision,
                  model.updates.value.windowRevision == work.snapshot.windowRevision,
                  currentEnvironment == work.environment else {
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
            let geometryChanged = installedGeometry != geometry || layoutEnvironment != environment
            let heightsChanged = layoutEnvironment != environment
            let newlyVisibleResizeRows = needsFullHeightRefresh ? heightRefreshIndexes.subtracting(liveResizeRows) : IndexSet()
            if !newlyVisibleResizeRows.isEmpty { heightSettlementRevision = -1 }
            guard latestSnapshot != nil || geometryChanged || !newlyVisibleResizeRows.isEmpty else { break }
            let snapshot = latestSnapshot
            latestSnapshot = nil
            let dataChanged = prepared != nil
            let position = geometryChanged ? settledPosition ?? capturePosition() : capturePosition()
            let layoutChanged = dataChanged || geometryChanged || !newlyVisibleResizeRows.isEmpty
            if layoutChanged {
                stopScrolling()
                installedGeometry = geometry
                layoutEnvironment = environment
                measuredWidth = geometry.rowWidth
                var changedHeights = exposedHeightChanges
                exposedHeightChanges.removeAll()
                if let work = prepared {
                    for (index, row) in work.snapshot.rows.enumerated() {
                        if installedLayouts[row.id]?.size.height != work.layouts[row.id]?.size.height { changedHeights.insert(index) }
                    }
                    presentations = work.presentations
                    installedLayouts = work.layouts
                    needsFullHeightRefresh = false
                    profileNeedsPreparation = false
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
                    for index in heightRefreshIndexes where heightsChanged || !liveResizeRows.contains(index) && needsFullHeightRefresh {
                        let oldHeight = installedLayouts[rows[index].id]?.size.height
                        let layout = exactLayout(for: rows[index])
                        liveResizeRows.insert(index)
                        if oldHeight != layout.size.height { changedHeights.insert(index) }
                    }
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    column.width = measuredWidth
                    if let snapshot, dataChanged { installRows(snapshot, changedHeights: changedHeights) }
                    else if !changedHeights.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: changedHeights) }
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
                        scroll(to: bottomOrigin, animated: !geometryChanged && snapshot?.animateFollowing == true, requestID: nil)
                    } else {
                        restore(position)
                    }
                }
            }
            settleExposedRows(preserving: capturePosition())
            if scrollTask == nil { settledPosition = capturePosition() }
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
        let change = reset ? TimelineChange.reset : TimelineChange.compute(from: rows, to: snapshot.rows)
        layoutCache.remove(oldIDs.subtracting(newIDs))
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
                guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TimelineTableCellView else { continue }
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

    private func capturePosition() -> Position {
        let visible = scrollView.documentVisibleRect
        let range = tableView.rows(in: visible)
        if range.location != NSNotFound, range.length > 0 {
            let upperBound = min(NSMaxRange(range), rows.count)
            if range.location < upperBound,
               let index = (range.location ..< upperBound).first(where: {
                   if case .message = rows[$0] { return true }
                   return false
               }) {
                return Position(messageID: rows[index].id, offset: tableView.rect(ofRow: index).minY - visible.minY, originY: visible.minY)
            }
        }
        return Position(messageID: nil, offset: 0, originY: visible.minY)
    }

    private func restore(_ position: Position) {
        let y: CGFloat
        if let id = position.messageID, let index = rows.firstIndex(where: { $0.id == id }) {
            y = tableView.rect(ofRow: index).minY - position.offset
        } else {
            // The anchor may have been deleted or replaced with another history window.
            y = position.originY
        }
        setScrollOrigin(constrainedOrigin(y: y))
    }

    private var bottomOrigin: NSPoint {
        constrainedOrigin(y: tableView.bounds.maxY - scrollView.contentView.bounds.height + scrollView.contentInsets.bottom)
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
        case .reveal(let id, let animated, let highlight):
            guard let index = rows.firstIndex(where: { $0.id == id }) else {
                finishRequest(id: request.id)
                return
            }
            prepareScrollTarget(index)
            if highlight && beginHighlight { highlightRow(id) }
            let frame = tableView.rect(ofRow: index)
            let target = constrainedOrigin(y: id == .unreadSeparator
                ? frame.minY - scrollView.contentInsets.top
                : frame.midY - scrollView.contentView.bounds.height / 2)
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
        let generation = scrollGeneration
        let startedAt = ProcessInfo.processInfo.systemUptime
        // Direct clip-view steps are cancellable without assuming AppKit's animator uses
        // a backing layer. Cancellation prevents all remaining physical scroll writes.
        scrollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self, self.scrollGeneration == generation else { return }
                self.installIfPossible()
                guard self.scrollGeneration == generation else { return }
                let progress = CGFloat(min(1, (ProcessInfo.processInfo.systemUptime - startedAt) / 0.25))
                let eased = progress * progress * (3 - 2 * progress)
                self.setScrollOrigin(NSPoint(x: start.x + (target.x - start.x) * eased, y: start.y + (target.y - start.y) * eased))
                guard self.scrollGeneration == generation else { return }
                if progress >= 1 {
                    self.scrollTask = nil
                    self.applying = true
                    self.settleExposedRows(preserving: self.capturePosition())
                    self.applying = false
                    if let requestID { self.finishRequest(id: requestID) }
                    self.installIfPossible()
                    self.reportViewport(reason: .programmatic)
                    return
                }
            }
        }
    }

    private func stopScrolling() {
        scrollGeneration &+= 1
        scrollTask?.cancel()
        scrollTask = nil
    }

    private func finishRequest(id: Int) {
        guard activeRequest?.id == id, installedRevision == model.updates.value.revision else { return }
        activeRequest = nil
        model.scrollRequestDidFinish(id: id)
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
              let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TimelineTableCellView else { return }
        bind(cell, row: rows[index])
    }

    private var heightRefreshIndexes: IndexSet {
        let visible = tableView.rows(in: scrollView.documentVisibleRect)
        guard visible.location != NSNotFound else { return [] }
        return IndexSet(integersIn: max(0, visible.location) ..< min(NSMaxRange(visible), rows.count))
    }

    @objc private func windowWillResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === view.window else { return }
        windowLiveResizing = true
        cancelHeightSettlement()
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === view.window else { return }
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
              layoutEnvironment == currentEnvironment else { return false }
        // Do not repeatedly interrupt an owned scroll animation with corrections.
        guard scrollTask == nil else { return true }
        if heightSettlementRevision != installedRevision || heightSettlementGeometry != installedGeometry {
            heightSettlementRevision = installedRevision
            heightSettlementGeometry = installedGeometry
            nextHeightSettlementRow = 0
            let visible = scrollView.documentVisibleRect
            let range = tableView.rows(in: visible.insetBy(dx: 0, dy: -visible.height))
            let priority = range.location == NSNotFound ? IndexSet() :
                IndexSet(integersIn: max(0, range.location) ..< min(NSMaxRange(range), rows.count))
            heightSettlementOrder = Array(priority) + rows.indices.filter { !priority.contains($0) }
            heightSettlementPriorityCount = priority.count
        }
        let position = capturePosition()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.004
        let settlementEnd = windowLiveResizing || isSplitResizing ? heightSettlementPriorityCount : heightSettlementOrder.count
        let upperBound = min(settlementEnd, nextHeightSettlementRow + 32)
        guard nextHeightSettlementRow < settlementEnd else { return false }
        var changed = IndexSet()
        applying = true
        while nextHeightSettlementRow < upperBound {
            let index = heightSettlementOrder[nextHeightSettlementRow]
            nextHeightSettlementRow += 1
            if !liveResizeRows.contains(index) {
                let previousHeight = installedLayouts[rows[index].id]?.size.height
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
        if (windowLiveResizing || isSplitResizing), nextHeightSettlementRow >= heightSettlementPriorityCount { return false }
        if nextHeightSettlementRow < heightSettlementOrder.count
            || heightSettlementRevision != installedRevision
            || heightSettlementGeometry != installedGeometry {
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
            openMedia: actions.openMedia == nil ? nil : { [weak self] in self?.actions.openMedia?($0, $1, $2) },
            openReply: actions.openReply == nil ? nil : { [weak self] in self?.actions.openReply?($0) },
            replyToMessage: actions.replyToMessage == nil ? nil : { [weak self] in self?.actions.replyToMessage?($0) },
            editMessage: actions.editMessage == nil ? nil : { [weak self] in self?.actions.editMessage?($0) },
            openThread: actions.openThread == nil ? nil : { [weak self] in self?.actions.openThread?($0) },
            openLink: actions.openLink == nil ? nil : { [weak self] in self?.actions.openLink?($0) },
            openMention: actions.openMention == nil ? nil : { [weak self] in self?.actions.openMention?($0) },
            openFailedMessage: actions.openFailedMessage == nil ? nil : { [weak self] in self?.actions.openFailedMessage?($0) },
            openContextMenu: actions.openContextMenu == nil ? nil : { [weak self] in self?.actions.openContextMenu?($0, $1) },
            toggleReaction: actions.toggleReaction == nil ? nil : { [weak self] in self?.actions.toggleReaction?($0, $1) },
            pendingReactionMessageIDs: actions.pendingReactionMessageIDs,
            currentUserProfile: actions.currentUserProfile,
            interactionContext: actions.interactionContext,
            modifiablePendingMessageIDs: actions.modifiablePendingMessageIDs,
            blockPendingMessage: actions.blockPendingMessage == nil ? nil : { [weak self] in self?.actions.blockPendingMessage?($0) },
            revokePendingMessage: actions.revokePendingMessage == nil ? nil : { [weak self] in self?.actions.revokePendingMessage?($0) }
        )
    }

    private func rowContext(for row: TimelineRow) -> TimelineRowContext {
        .init(
            isHighlighted: row.id == highlightedRowID,
            currentUserID: model.currentUserID,
            isThreadTimeline: model.threadID != nil
        )
    }

    private func refreshVisibleRoots() {
        let visible = tableView.rows(in: scrollView.documentVisibleRect)
        guard visible.location != NSNotFound else { return }
        for index in visible.location ..< min(NSMaxRange(visible), rows.count) {
            guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TimelineTableCellView else { continue }
            bind(cell, row: rows[index])
        }
    }

    @objc private func boundsChanged() {
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
        guard let window = notification.object as? NSWindow, window === view.window else { return }
        installIfPossible()
    }

    private func cancelForUserScroll() {
        stopScrolling()
        activeRequest = nil
        settledPosition = capturePosition()
        model.userScrollBegan()
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

    private func reportViewport(reason: TimelineViewportChangeReason) {
        guard !applying, !settingScrollOrigin, !handlingWheel, scrollTask == nil,
              latestSnapshot == nil, installedRevision >= 0, installedRevision == model.updates.value.revision,
              installedGeometry == currentGeometry, layoutEnvironment == currentEnvironment,
              !liveScrolling || reason == .user else { return }
        let visible = scrollView.documentVisibleRect
        guard visible.height > 0 else { return }
        let range = tableView.rows(in: visible)
        let hasVisibleRows = range.location != NSNotFound && range.length > 0 && range.location < rows.count
        // AppKit's documentVisibleRect includes content underneath the floating chrome.
        // Preserve the existing pagination/anchor geometry, but never count obscured rows as read.
        let insets = scrollView.contentInsets
        let unobscured = NSRect(
            x: visible.minX + insets.left,
            y: visible.minY + insets.top,
            width: max(0, visible.width - insets.left - insets.right),
            height: max(0, visible.height - insets.top - insets.bottom)
        )
        var fullyVisibleMessageIDs: [String] = []
        if hasVisibleRows, !unobscured.isEmpty {
            for index in range.location ..< min(NSMaxRange(range), rows.count) {
                guard let id = rows[index].messageID,
                      unobscured.contains(tableView.rect(ofRow: index)) else { continue }
                fullyVisibleMessageIDs.append(id)
            }
        }
        settledPosition = capturePosition()
        model.viewportDidChange(.init(
            firstVisibleIndex: hasVisibleRows ? range.location : nil,
            lastVisibleIndex: hasVisibleRows ? min(NSMaxRange(range), rows.count) - 1 : nil,
            distanceToTop: max(0, visible.minY + scrollView.contentInsets.top),
            distanceToBottom: max(0, tableView.bounds.maxY + scrollView.contentInsets.bottom - visible.maxY),
            height: visible.height,
            fullyVisibleMessageIDs: fullyVisibleMessageIDs
        ), reason: reason, revision: installedRevision)
    }
}
#endif
