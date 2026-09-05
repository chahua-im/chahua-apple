#if os(iOS)
import Combine
import SwiftUI
import UIKit

@MainActor
final class TimelineCollectionViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
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

    private let collectionView: UICollectionView = {
        let layout = TimelineFlowLayout()
        layout.minimumLineSpacing = 0
        layout.sectionInset = .zero
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()

    init(model: ConversationTimelineModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor), collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor), collectionView.topAnchor.constraint(equalTo: view.topAnchor), collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        collectionView.dataSource = self; collectionView.delegate = self; collectionView.keyboardDismissMode = .interactive
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "timeline")
        measurer = TimelineRowMeasurer(parent: self)
        cancellable = model.updates.sink { [weak self] in self?.receive($0) }
    }

    private var availableRowWidth: CGFloat {
        max(0, collectionView.bounds.width - collectionView.adjustedContentInset.left - collectionView.adjustedContentInset.right)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = availableRowWidth
        if width != measuredWidth {
            let anchor = captureAnchor()
            let wasApplying = applying
            applying = true
            measuredWidth = width
            measurer.invalidateAll()
            collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if model.state.live.followsLatest && model.isAtLiveEdge {
                scrollToBottom(animated: false)
            } else {
                restore(anchor)
            }
            applying = wasApplying
        }
        installIfPossible()
        reportViewport(reason: .layout)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "timeline", for: indexPath)
        let row = rows[indexPath.item]
        cell.contentConfiguration = UIHostingConfiguration { TimelineBubbleView(row: row, context: .init(isHighlighted: row.id == highlightedRowID)) }.margins(.all, 0)
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        // Flow layout can request metrics before the parent's viewDidLayoutSubviews runs.
        let width = availableRowWidth
        return .init(width: width, height: measurer.height(for: rows[indexPath.item], width: width))
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { model.userScrollBegan() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { guard !applying else { return }; reportViewport(reason: .user) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { reportViewport(reason: .user) } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportViewport(reason: .user) }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finishRequestIfCurrent(); reportViewport(reason: .programmatic) }

    private func receive(_ snapshot: TimelineHostSnapshot) { latestSnapshot = snapshot; installIfPossible() }
    private func installIfPossible() {
        guard !applying, let snapshot = latestSnapshot, collectionView.bounds.width > 0, collectionView.bounds.height > 0 else { return }
        latestSnapshot = nil
        let reset = installedWindowRevision != snapshot.windowRevision || installedRevision < 0
        applying = true
        let oldIDs = Set(rows.map(\.id)); let newIDs = Set(snapshot.rows.map(\.id)); let removed = oldIDs.subtracting(newIDs)
        let anchor = snapshot.pendingScroll == nil && !model.state.live.followsLatest ? captureAnchor() : nil
        let change = reset ? TimelineChange.reset : TimelineChange.compute(from: rows, to: snapshot.rows)
        switch change {
        case .reset: rows = snapshot.rows; collectionView.reloadData()
        case .incremental(let removals, let insertions, let reloads):
            rows = snapshot.rows
            collectionView.performBatchUpdates {
                collectionView.deleteItems(at: removals.map { .init(item: $0, section: 0) })
                collectionView.insertItems(at: insertions.map { .init(item: $0, section: 0) })
            }
            if !reloads.isEmpty { collectionView.reconfigureItems(at: reloads.map { .init(item: $0, section: 0) }) }
        }
        measurer.remove(removed)
        collectionView.collectionViewLayout.invalidateLayout(); collectionView.layoutIfNeeded()
        installedRevision = snapshot.revision; installedWindowRevision = snapshot.windowRevision
        if let request = snapshot.pendingScroll { execute(request) }
        else if model.state.live.followsLatest && model.isAtLiveEdge { scrollToBottom(animated: snapshot.animateFollowing) }
        else { restore(anchor) }
        applying = false
        reportViewport(reason: .programmatic)
    }

    private func captureAnchor() -> (TimelineRowID, CGFloat)? { let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top; return collectionView.indexPathsForVisibleItems.sorted().compactMap { path in collectionView.layoutAttributesForItem(at: path).map { (rows[path.item].id, $0.frame.minY - top) } }.first }
    private func restore(_ anchor: (TimelineRowID, CGFloat)?) { guard let anchor, let index = rows.firstIndex(where: { $0.id == anchor.0 }), let frame = collectionView.layoutAttributesForItem(at: .init(item: index, section: 0))?.frame else { return }; collectionView.contentOffset.y = frame.minY - anchor.1 - collectionView.adjustedContentInset.top }
    private func execute(_ request: TimelineScrollRequest) { switch request.intent { case .bottom(let animated): scrollToBottom(animated: animated); if !animated { finishRequestIfCurrent() }; case .reveal(let id, let animated, let highlight): reveal(id, animated: animated, highlight: highlight); if !animated { finishRequestIfCurrent() } } }
    private func scrollToBottom(animated: Bool) { let y = max(-collectionView.adjustedContentInset.top, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom); collectionView.setContentOffset(.init(x: 0, y: y), animated: animated) }
    private func reveal(_ id: TimelineRowID, animated: Bool, highlight: Bool) { guard let index = rows.firstIndex(where: { $0.id == id }) else { return }; collectionView.scrollToItem(at: .init(item: index, section: 0), at: .centeredVertically, animated: animated); guard highlight else { return }; highlightedRowID = id; collectionView.reconfigureItems(at: [.init(item: index, section: 0)]); highlightTask?.cancel(); highlightTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(1.5)) } catch { return }; guard let self, self.highlightedRowID == id, let current = self.rows.firstIndex(where: { $0.id == id }) else { return }; self.highlightedRowID = nil; self.collectionView.reconfigureItems(at: [.init(item: current, section: 0)]) } }
    private func finishRequestIfCurrent() { if let request = model.updates.value.pendingScroll, installedRevision == model.updates.value.revision { model.scrollRequestDidFinish(id: request.id) } }
    private func reportViewport(reason: TimelineViewportChangeReason) { let visible = collectionView.indexPathsForVisibleItems; let top = max(0, collectionView.contentOffset.y + collectionView.adjustedContentInset.top); let height = max(0, collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom); model.viewportDidChange(.init(firstVisibleIndex: visible.map(\.item).min(), lastVisibleIndex: visible.map(\.item).max(), distanceToTop: top, distanceToBottom: max(0, collectionView.contentSize.height - top - height), height: height), reason: reason, revision: installedRevision) }
}

private final class TimelineFlowLayout: UICollectionViewFlowLayout {
    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if newBounds.width != collectionView?.bounds.width,
           let context = context as? UICollectionViewFlowLayoutInvalidationContext {
            context.invalidateFlowLayoutDelegateMetrics = true
        }
        return context
    }
}
#endif
