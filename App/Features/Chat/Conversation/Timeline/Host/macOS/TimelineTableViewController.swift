#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
final class TimelineTableCellView: NSTableCellView {
    let hosting = NSHostingView(rootView: TimelineBubbleView(row: .dateSeparator(.init(day: .now, ordinalDay: 0)), context: .init()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
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
    private var measuredWidth: CGFloat = 0

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

#if DEBUG
    var renderedRowCountForTesting: Int { tableView.numberOfRows }
    func measuredHeightForTesting(row: Int) -> CGFloat { tableView(tableView, heightOfRow: row) }
#endif
    private let column = NSTableColumn(identifier: .init("timeline"))

    init(model: ConversationTimelineModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = NSView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        tableView.headerView = nil
        tableView.addTableColumn(column)
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.usesAutomaticRowHeights = false
        tableView.delegate = self; tableView.dataSource = self
        scrollView.documentView = tableView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor), scrollView.topAnchor.constraint(equalTo: view.topAnchor), scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        measurer = TimelineRowMeasurer(parent: self)
        rows = model.rows; tableView.reloadData()
        cancellable = model.updates.sink { [weak self] in self?.apply($0) }
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard column.width != measuredWidth else { return }
        measuredWidth = column.width
        measurer.invalidateAll()
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0 ..< rows.count))
        tableView.layoutSubtreeIfNeeded()
        reportViewport()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { measurer.height(for: rows[row], width: column.width) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("timeline")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TimelineTableCellView ?? TimelineTableCellView()
        cell.identifier = id
        let item = rows[row]
        cell.hosting.rootView = TimelineBubbleView(row: item, context: .init(isHighlighted: item.id == highlightedRowID))
        return cell
    }

    private func apply(_ update: TimelineHostUpdate) {
        let anchor = update.scroll == .preserveAnchor ? captureAnchor() : nil
        let previous = rows
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            switch update.change {
            case .reset:
                rows = update.rows
                tableView.reloadData()
            case .incremental(let removals, let insertions, let reloads):
                tableView.beginUpdates()
                rows = update.rows
                tableView.removeRows(at: removals, withAnimation: [])
                tableView.insertRows(at: insertions, withAnimation: [])
                tableView.endUpdates()
                if !reloads.isEmpty { tableView.reloadData(forRowIndexes: reloads, columnIndexes: IndexSet(integer: 0)) }
            }
        }
        tableView.layoutSubtreeIfNeeded(); measurer.retain(only: Set(rows.map(\.id)))
        switch update.scroll { case .preserveAnchor: restore(anchor, previous: previous); case .bottom(let animated): scrollToBottom(animated: animated); case .reveal(let id, let animated, let highlight): reveal(id, animated: animated, highlight: highlight) }
        reportViewport()
    }

    private func captureAnchor() -> (TimelineRowID, CGFloat)? { let visible = scrollView.documentVisibleRect; let range = tableView.rows(in: visible); guard range.location != NSNotFound, range.length > 0 else { return nil }; let index = range.location; return (rows[index].id, tableView.rect(ofRow: index).minY - visible.minY) }
    private func restore(_ anchor: (TimelineRowID, CGFloat)?, previous: [TimelineRow]) { guard let anchor, let index = rows.firstIndex(where: { $0.id == anchor.0 }) else { return }; scrollView.contentView.scroll(to: .init(x: 0, y: max(0, tableView.rect(ofRow: index).minY - anchor.1))); scrollView.reflectScrolledClipView(scrollView.contentView) }
    private func scrollToBottom(animated: Bool) { let target = NSPoint(x: 0, y: max(0, tableView.bounds.height - scrollView.contentView.bounds.height)); if animated { NSAnimationContext.runAnimationGroup { $0.duration = 0.25; scrollView.contentView.animator().setBoundsOrigin(target) } } else { scrollView.contentView.scroll(to: target) }; scrollView.reflectScrolledClipView(scrollView.contentView) }
    private func reveal(_ id: TimelineRowID, animated: Bool, highlight: Bool) { guard let index = rows.firstIndex(where: { $0.id == id }) else { return }; let rect = tableView.rect(ofRow: index); let target = NSPoint(x: 0, y: max(0, rect.midY - scrollView.contentView.bounds.height / 2)); if animated { NSAnimationContext.runAnimationGroup { $0.duration = 0.25; scrollView.contentView.animator().setBoundsOrigin(target) } } else { scrollView.contentView.scroll(to: target) }; scrollView.reflectScrolledClipView(scrollView.contentView); guard highlight else { return }; highlightedRowID = id; tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0)); highlightTask?.cancel(); highlightTask = Task { [weak self] in try? await Task.sleep(for: .seconds(1.5)); guard let self, highlightedRowID == id, let current = rows.firstIndex(where: { $0.id == id }) else { return }; highlightedRowID = nil; tableView.reloadData(forRowIndexes: IndexSet(integer: current), columnIndexes: IndexSet(integer: 0)) } }
    @objc private func boundsChanged() { reportViewport() }
    private func reportViewport() { let visible = scrollView.documentVisibleRect; let range = tableView.rows(in: visible); model.viewportDidChange(.init(firstVisibleIndex: range.location == NSNotFound ? nil : range.location, lastVisibleIndex: range.location == NSNotFound ? nil : range.location + range.length - 1, distanceToTop: max(0, visible.minY), distanceToBottom: max(0, tableView.bounds.height - visible.maxY), height: visible.height)) }
}
#endif
