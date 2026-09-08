#if os(macOS)
import AppKit
import ChahuaAPI
import Combine
import SwiftUI

@MainActor
final class TimelineTableCellView: NSTableCellView {
    let hosting = NSHostingView(rootView: TimelineBubbleView(row: .dateSeparator(.init(day: .now, ordinalDay: 0)), context: .init()))
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); hosting.translatesAutoresizingMaskIntoConstraints = false; addSubview(hosting); NSLayoutConstraint.activate([hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor), hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor)]) }
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
            refreshVisibleRoots()
        }
    }
    var mediaContext: AppMediaContext? {
        didSet {
            guard mediaContext !== oldValue, isViewLoaded else { return }
            refreshVisibleRoots()
        }
    }

    var colorScheme: ColorScheme = .light {
        didSet {
            guard isViewLoaded else { return }
            applyConversationBackground()
        }
    }
    private var measurer: TimelineRowMeasurer!
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
    private var liveResizing = false
    private var needsFullHeightRefresh = false
    private var liveResizeRows = IndexSet()
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
        measurer = TimelineRowMeasurer(parent: self)
        cancellable = model.updates.sink { [weak self] in self?.receive($0) }
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        notifications.addObserver(self, selector: #selector(userWillScroll), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        notifications.addObserver(self, selector: #selector(userDidScroll), name: NSScrollView.didLiveScrollNotification, object: scrollView)
        notifications.addObserver(self, selector: #selector(userDidEndScroll), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        notifications.addObserver(self, selector: #selector(backingPropertiesChanged(_:)), name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
        notifications.addObserver(self, selector: #selector(windowWillResize(_:)), name: NSWindow.willStartLiveResizeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(windowDidResize(_:)), name: NSWindow.didEndLiveResizeNotification, object: nil)
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
        installIfPossible()
        reportViewport(reason: .layout)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if liveResizing, !liveResizeRows.contains(row), let height = measurer.cachedHeight(for: rows[row]) {
            return height
        }
        return measurer.height(for: rows[row], width: measuredWidth, context: rowContext(for: rows[row]))
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("timeline")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TimelineTableCellView ?? TimelineTableCellView()
        cell.identifier = id
        let item = rows[row]
        cell.hosting.rootView = TimelineBubbleView(row: item, context: rowContext(for: item), actions: actions, mediaContext: mediaContext)
        return cell
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
        guard snapshot.revision >= installedRevision,
              snapshot.revision >= (latestSnapshot?.revision ?? installedRevision) else { return }
        latestSnapshot = snapshot
        installIfPossible()
    }

    private func installIfPossible() {
        guard !applying, measurer != nil else { return }
        applying = true
        var didWork = false

        // Finishing a nonanimated request publishes synchronously. Drain that intent-only
        // snapshot here instead of leaving it queued behind the applying guard.
        while true {
            let geometry = currentGeometry
            guard geometry.rowWidth > 0, geometry.size.height > 0 else { break }
            let geometryChanged = installedGeometry != geometry || (needsFullHeightRefresh && !liveResizing)
            guard latestSnapshot != nil || geometryChanged else { break }
            let snapshot = latestSnapshot
            latestSnapshot = nil
            let dataChanged = snapshot.map { $0.revision != installedRevision } ?? false
            let position = geometryChanged ? settledPosition ?? capturePosition() : capturePosition()
            let typographyChanged = installedGeometry?.fontSize != geometry.fontSize
            let heightsChanged = installedGeometry?.rowWidth != geometry.rowWidth
                || installedGeometry?.size.height != geometry.size.height
                || installedGeometry?.scale != geometry.scale
                || installedGeometry?.fontSize != geometry.fontSize
                || (needsFullHeightRefresh && !liveResizing)

            if dataChanged || geometryChanged {
                // Stop before row coordinates change; an active request will be retargeted
                // against the newly laid-out rows, never its old animation destination.
                stopScrolling()
                installedGeometry = geometry
                if liveResizing { liveResizeRows = heightRefreshIndexes }
                measuredWidth = geometry.rowWidth
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    column.width = measuredWidth
                    if geometryChanged { refreshVisibleRoots(geometryOnly: !typographyChanged) }
                    if let snapshot, dataChanged {
                        installRows(snapshot, invalidateHeights: heightsChanged)
                    } else if heightsChanged, !rows.isEmpty {
                        tableView.noteHeightOfRows(withIndexesChanged: heightRefreshIndexes)
                    }
                    if heightsChanged { needsFullHeightRefresh = liveResizing }
                    tableView.layoutSubtreeIfNeeded()
                    scrollView.layoutSubtreeIfNeeded()
                }
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
                    } else if activeRequest?.id == request.id, dataChanged || geometryChanged {
                        execute(request, beginHighlight: false)
                    }
                } else if dataChanged || geometryChanged {
                    if model.state.live.followsLatest && model.isAtLiveEdge {
                        scroll(to: bottomOrigin, animated: !geometryChanged && snapshot?.animateFollowing == true, requestID: nil)
                    } else {
                        restore(position)
                    }
                }
            }
            if scrollTask == nil { settledPosition = capturePosition() }
            didWork = true
        }

        applying = false
        if didWork { reportViewport(reason: .programmatic) }
    }

    private func installRows(_ snapshot: TimelineHostSnapshot, invalidateHeights: Bool) {
        let oldIDs = Set(rows.map(\.id))
        let newIDs = Set(snapshot.rows.map(\.id))
        let reset = installedRevision < 0 || installedWindowRevision != snapshot.windowRevision
        let change = reset ? TimelineChange.reset : TimelineChange.compute(from: rows, to: snapshot.rows)
        measurer.remove(oldIDs.subtracting(newIDs))
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
            if !reloads.isEmpty {
                tableView.reloadData(forRowIndexes: reloads, columnIndexes: IndexSet(integer: 0))
            }
            // Insertions acquire their own heights. Only changed survivors need notifying
            // unless the measurement environment changed for the entire table.
            let changedHeights = invalidateHeights ? heightRefreshIndexes.union(reloads.subtracting(insertions)) : reloads.subtracting(insertions)
            if !changedHeights.isEmpty {
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
            scroll(to: bottomOrigin, animated: animated, requestID: request.id)
        case .reveal(let id, let animated, let highlight):
            guard let index = rows.firstIndex(where: { $0.id == id }) else {
                finishRequest(id: request.id)
                return
            }
            if highlight && beginHighlight { highlightRow(id) }
            let target = constrainedOrigin(y: tableView.rect(ofRow: index).midY - scrollView.contentView.bounds.height / 2)
            scroll(to: target, animated: animated, requestID: request.id)
        }
    }

    private func scroll(to target: NSPoint, animated: Bool, requestID: Int?) {
        stopScrolling()
        let start = scrollView.contentView.bounds.origin
        guard animated, abs(start.y - target.y) > 0.5 || abs(start.x - target.x) > 0.5 else {
            setScrollOrigin(target)
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
        cell.hosting.rootView = TimelineBubbleView(row: rows[index], context: rowContext(for: rows[index]), actions: actions, mediaContext: mediaContext)
    }

    private var heightRefreshIndexes: IndexSet {
        guard liveResizing else { return IndexSet(rows.indices) }
        let visible = tableView.rows(in: scrollView.documentVisibleRect)
        guard visible.location != NSNotFound else { return [] }
        return IndexSet(integersIn: max(0, visible.location - 2) ..< min(NSMaxRange(visible) + 2, rows.count))
    }

    @objc private func windowWillResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === view.window else { return }
        liveResizing = true
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === view.window else { return }
        liveResizing = false
        installIfPossible()
    }

    private func rowContext(for row: TimelineRow) -> TimelineRowContext {
        let dependsOnViewportHeight: Bool
        if case .message(let message) = row {
            dependsOnViewportHeight = !(message.entry.remoteMessage?.attachments.isEmpty ?? true)
        } else {
            dependsOnViewportHeight = false
        }
        return .init(
            isHighlighted: row.id == highlightedRowID,
            viewportSize: dependsOnViewportHeight ? CGSize(width: currentGeometry.rowWidth, height: currentGeometry.size.height) : .zero,
            currentUserID: model.currentUserID,
            isThreadTimeline: model.threadID != nil
        )
    }

    private func refreshVisibleRoots(geometryOnly: Bool = false) {
        let visible = tableView.rows(in: scrollView.documentVisibleRect)
        guard visible.location != NSNotFound else { return }
        for index in visible.location ..< min(NSMaxRange(visible), rows.count) {
            guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TimelineTableCellView else { continue }
            let context = rowContext(for: rows[index])
            if geometryOnly, cell.hosting.rootView.context == context { continue }
            cell.hosting.rootView = TimelineBubbleView(row: rows[index], context: context, actions: actions, mediaContext: mediaContext)
        }
    }

    @objc private func boundsChanged() {
        guard !applying, !settingScrollOrigin, !handlingWheel else { return }
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
              latestSnapshot == nil, installedRevision >= 0, installedGeometry == currentGeometry,
              !liveScrolling || reason == .user else { return }
        let visible = scrollView.documentVisibleRect
        guard visible.height > 0 else { return }
        let range = tableView.rows(in: visible)
        let hasVisibleRows = range.location != NSNotFound && range.length > 0 && range.location < rows.count
        settledPosition = capturePosition()
        model.viewportDidChange(.init(
            firstVisibleIndex: hasVisibleRows ? range.location : nil,
            lastVisibleIndex: hasVisibleRows ? min(NSMaxRange(range), rows.count) - 1 : nil,
            distanceToTop: max(0, visible.minY + scrollView.contentInsets.top),
            distanceToBottom: max(0, tableView.bounds.maxY + scrollView.contentInsets.bottom - visible.maxY),
            height: visible.height
        ), reason: reason, revision: installedRevision)
    }
}
#endif
