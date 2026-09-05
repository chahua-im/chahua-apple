#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
final class TimelineTableCellView: NSTableCellView {
    let hosting = NSHostingView(rootView: TimelineBubbleView(row: .dateSeparator(.init(day: .now, ordinalDay: 0)), context: .init()))
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); hosting.translatesAutoresizingMaskIntoConstraints = false; addSubview(hosting); NSLayoutConstraint.activate([hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor), hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor)]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class TimelineTableViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: ConversationTimelineModel
    private var rows: [TimelineRow] = []
    private var measurer: TimelineRowMeasurer!
    private var cancellable: AnyCancellable?
    private var highlightedRowID: TimelineRowID?
    private var highlightTask: Task<Void, Never>?
    private var latestSnapshot: TimelineHostSnapshot?
    private var installedRevision = -1
    private var installedWindowRevision = -1
    private var measuredWidth: CGFloat = 0
    private var applying = false
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let column = NSTableColumn(identifier: .init("timeline"))

    init(model: ConversationTimelineModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
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
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidLayout() { super.viewDidLayout(); let width = scrollView.contentView.bounds.width; column.width = width; if width != measuredWidth { measuredWidth = width; measurer.invalidateAll(); tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0 ..< rows.count)) }; installIfPossible(); reportViewport(reason: .layout) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { measurer.height(for: rows[row], width: measuredWidth) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { let id = NSUserInterfaceItemIdentifier("timeline"); let cell = tableView.makeView(withIdentifier: id, owner: self) as? TimelineTableCellView ?? TimelineTableCellView(); cell.identifier = id; let item = rows[row]; cell.hosting.rootView = TimelineBubbleView(row: item, context: .init(isHighlighted: item.id == highlightedRowID)); return cell }
    private func receive(_ snapshot: TimelineHostSnapshot) { latestSnapshot = snapshot; installIfPossible() }
    private func installIfPossible() { guard !applying, let snapshot = latestSnapshot, measuredWidth > 0, scrollView.contentView.bounds.height > 0 else { return }; latestSnapshot = nil; applying = true; let reset = installedWindowRevision != snapshot.windowRevision || installedRevision < 0; let anchor = snapshot.pendingScroll == nil && !model.state.live.followsLatest ? captureAnchor() : nil; let oldIDs = Set(rows.map(\.id)); let newIDs = Set(snapshot.rows.map(\.id)); let change = reset ? TimelineChange.reset : TimelineChange.compute(from: rows, to: snapshot.rows); switch change { case .reset: rows = snapshot.rows; tableView.reloadData(); case .incremental(let removals, let insertions, let reloads): tableView.beginUpdates(); rows = snapshot.rows; tableView.removeRows(at: removals, withAnimation: []); tableView.insertRows(at: insertions, withAnimation: []); tableView.endUpdates(); if !reloads.isEmpty { tableView.reloadData(forRowIndexes: reloads, columnIndexes: IndexSet(integer: 0)) } }; measurer.remove(oldIDs.subtracting(newIDs)); tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0 ..< rows.count)); tableView.layoutSubtreeIfNeeded(); installedRevision = snapshot.revision; installedWindowRevision = snapshot.windowRevision; if let request = snapshot.pendingScroll { execute(request) } else if model.state.live.followsLatest && model.isAtLiveEdge { scrollToBottom(animated: snapshot.animateFollowing) } else { restore(anchor) }; applying = false; reportViewport(reason: .programmatic) }
    private func captureAnchor() -> (TimelineRowID, CGFloat)? {
        let visible = scrollView.documentVisibleRect
        let range = tableView.rows(in: visible)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        // Same-day history is inserted below its date separator, so anchor the reader's message instead.
        let index = (range.location ..< NSMaxRange(range)).first {
            if case .message = rows[$0] { return true }
            return false
        } ?? range.location
        return (rows[index].id, tableView.rect(ofRow: index).minY - visible.minY)
    }
    private func restore(_ anchor: (TimelineRowID, CGFloat)?) { guard let anchor, let index = rows.firstIndex(where: { $0.id == anchor.0 }) else { return }; scrollView.contentView.scroll(to: .init(x: 0, y: max(0, tableView.rect(ofRow: index).minY - anchor.1))); scrollView.reflectScrolledClipView(scrollView.contentView) }
    private func execute(_ request: TimelineScrollRequest) { switch request.intent { case .bottom(let animated): scrollToBottom(animated: animated); if !animated { finishRequest() }; case .reveal(let id, let animated, let highlight): reveal(id, animated: animated, highlight: highlight); if !animated { finishRequest() } } }
    private func scrollToBottom(animated: Bool) { let target = NSPoint(x: 0, y: max(0, tableView.bounds.height - scrollView.contentView.bounds.height)); if animated { NSAnimationContext.runAnimationGroup { $0.duration = 0.25; scrollView.contentView.animator().setBoundsOrigin(target) } completionHandler: { [weak self] in self?.finishRequest() } } else { scrollView.contentView.scroll(to: target) }; scrollView.reflectScrolledClipView(scrollView.contentView) }
    private func reveal(_ id: TimelineRowID, animated: Bool, highlight: Bool) { guard let index = rows.firstIndex(where: { $0.id == id }) else { return }; let rect = tableView.rect(ofRow: index); scrollView.contentView.scroll(to: .init(x: 0, y: max(0, rect.midY - scrollView.contentView.bounds.height / 2))); scrollView.reflectScrolledClipView(scrollView.contentView); guard highlight else { return }; highlightedRowID = id; tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0)); highlightTask?.cancel(); highlightTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(1.5)) } catch { return }; guard let self, self.highlightedRowID == id, let current = self.rows.firstIndex(where: { $0.id == id }) else { return }; self.highlightedRowID = nil; self.tableView.reloadData(forRowIndexes: IndexSet(integer: current), columnIndexes: IndexSet(integer: 0)) } }
    private func finishRequest() { if let request = model.updates.value.pendingScroll, installedRevision == model.updates.value.revision { model.scrollRequestDidFinish(id: request.id) } }
    @objc private func boundsChanged() { guard !applying else { return }; reportViewport(reason: .layout) }
    @objc private func userWillScroll() { model.userScrollBegan() }
    @objc private func userDidScroll() {
        guard !applying else { return }
        // Legacy mouse wheels do not send willStart/didEnd live-scroll notifications.
        model.userScrollBegan()
        reportViewport(reason: .user)
    }
    private func reportViewport(reason: TimelineViewportChangeReason) { let visible = scrollView.documentVisibleRect; let range = tableView.rows(in: visible); model.viewportDidChange(.init(firstVisibleIndex: range.location == NSNotFound ? nil : range.location, lastVisibleIndex: range.location == NSNotFound ? nil : range.location + range.length - 1, distanceToTop: max(0, visible.minY), distanceToBottom: max(0, tableView.bounds.height - visible.maxY), height: visible.height), reason: reason, revision: installedRevision) }
}
#endif
