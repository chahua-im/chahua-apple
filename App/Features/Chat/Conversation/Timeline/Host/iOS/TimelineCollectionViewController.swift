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
    private var pendingScroll: TimelineScrollIntent?
    private var measuredWidth: CGFloat = 0

    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.estimatedItemSize = .zero
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.allowsSelection = false
        view.keyboardDismissMode = .interactive
        view.contentInsetAdjustmentBehavior = .always
        return view
    }()

    init(model: ConversationTimelineModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "timeline")
        measurer = TimelineRowMeasurer(parent: self)
        rows = model.rows
        collectionView.reloadData()
        cancellable = model.updates.sink { [weak self] in self?.apply($0) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard collectionView.bounds.width != measuredWidth else { return }
        measuredWidth = collectionView.bounds.width
        measurer.invalidateAll()
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
        reportViewport()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "timeline", for: indexPath)
        let row = rows[indexPath.item]
        cell.contentConfiguration = UIHostingConfiguration {
            TimelineBubbleView(row: row, context: .init(isHighlighted: row.id == highlightedRowID))
        }.margins(.all, 0)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: measurer.height(for: rows[indexPath.item], width: collectionView.bounds.width))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { reportViewport() }

    private func apply(_ update: TimelineHostUpdate) {
        guard collectionView.bounds.width > 0 else { rows = update.rows; collectionView.reloadData(); pendingScroll = update.scroll; return }
        let anchor = update.scroll == .preserveAnchor ? captureAnchor() : nil
        let previous = rows
        update.rows.forEach { _ = measurer.height(for: $0, width: collectionView.bounds.width) }
        UIView.performWithoutAnimation {
            switch update.change {
            case .reset:
                rows = update.rows
                collectionView.reloadData()
            case .incremental(let removals, let insertions, let reloads):
                guard !removals.isEmpty || !insertions.isEmpty || !reloads.isEmpty else { return }
                collectionView.performBatchUpdates {
                    rows = update.rows
                    collectionView.deleteItems(at: removals.map { IndexPath(item: $0, section: 0) })
                    collectionView.insertItems(at: insertions.map { IndexPath(item: $0, section: 0) })
                }
                if !reloads.isEmpty { collectionView.reconfigureItems(at: reloads.map { IndexPath(item: $0, section: 0) }) }
            }
            collectionView.layoutIfNeeded()
        }
        measurer.retain(only: Set(rows.map(\.id)))
        switch update.scroll {
        case .preserveAnchor: restore(anchor, previous: previous)
        case .bottom(let animated): scrollToBottom(animated: animated)
        case .reveal(let id, let animated, let highlight): reveal(id, animated: animated, highlight: highlight)
        }
        reportViewport()
    }

    private func captureAnchor() -> (TimelineRowID, CGFloat)? {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        for path in collectionView.indexPathsForVisibleItems.sorted() {
            guard let frame = collectionView.layoutAttributesForItem(at: path)?.frame, frame.maxY > top else { continue }
            return (rows[path.item].id, frame.minY - top)
        }
        return nil
    }

    private func restore(_ anchor: (TimelineRowID, CGFloat)?, previous: [TimelineRow]) {
        guard let anchor, let index = rows.firstIndex(where: { $0.id == anchor.0 }), let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        collectionView.contentOffset.y = frame.minY - anchor.1 - collectionView.adjustedContentInset.top
    }

    private func scrollToBottom(animated: Bool) {
        let y = max(-collectionView.adjustedContentInset.top, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    private func reveal(_ id: TimelineRowID, animated: Bool, highlight: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: animated)
        guard highlight else { return }
        highlightedRowID = id
        collectionView.reconfigureItems(at: [IndexPath(item: index, section: 0)])
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, highlightedRowID == id, let currentIndex = rows.firstIndex(where: { $0.id == id }) else { return }
            highlightedRowID = nil
            collectionView.reconfigureItems(at: [IndexPath(item: currentIndex, section: 0)])
        }
    }

    private func reportViewport() {
        let visible = collectionView.indexPathsForVisibleItems
        let top = max(0, collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
        let height = max(0, collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom)
        model.viewportDidChange(.init(firstVisibleIndex: visible.map(\.item).min(), lastVisibleIndex: visible.map(\.item).max(), distanceToTop: top, distanceToBottom: max(0, collectionView.contentSize.height - top - height), height: height))
    }
}
#endif
