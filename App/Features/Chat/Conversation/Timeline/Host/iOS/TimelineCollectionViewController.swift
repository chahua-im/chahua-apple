#if os(iOS)
import ChahuaAPI
import Combine
import SwiftUI
import UIKit

@MainActor
final class TimelineCollectionViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private struct Geometry: Equatable {
        let size: CGSize
        let insets: UIEdgeInsets

        var rowWidth: CGFloat {
            max(0, size.width - insets.left - insets.right)
        }
    }

    private struct Position {
        let messageID: TimelineRowID?
        let messageOffset: CGFloat
        let top: CGFloat
    }

    private struct ScrollAnimation {
        let targetY: CGFloat
        let requestID: Int?
    }

    private let model: ConversationTimelineModel
    private var rows: [TimelineRow] = []
    var actions: TimelineBubbleActions {
        didSet {
            guard isViewLoaded else { return }
            collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
        }
    }
    var mediaContext: AppMediaContext? {
        didSet {
            guard mediaContext !== oldValue, isViewLoaded else { return }
            collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
        }
    }

    var colorScheme: ColorScheme = .light {
        didSet {
            guard isViewLoaded else { return }
            applyConversationBackground()
        }
    }
    var headerInset: CGFloat = 0 {
        didSet {
            guard headerInset != oldValue, isViewLoaded else { return }
            collectionView.contentInset.top = headerInset
            collectionView.verticalScrollIndicatorInsets.top = headerInset
            view.setNeedsLayout()
        }
    }
    private var measurer: TimelineRowMeasurer!
    private var cancellable: AnyCancellable?
    private var highlightedRowID: TimelineRowID?
    private var highlightTask: Task<Void, Never>?
    private var highlightNeedsRefresh = false
    private var latestSnapshot: TimelineHostSnapshot?
    private var installedRevision = -1
    private var installedWindowRevision = -1
    private var geometry: Geometry?
    private var position: Position?
    private var desiredRequest: TimelineScrollRequest?
    private var activeRequest: TimelineScrollRequest?
    private var lastStartedRequestID = 0
    private var scrollAnimation: ScrollAnimation?
    private var needsPlacement = false
    private var animateFollowing = false
    private var userScrolling = false
    private var applying = false
    private var draining = false

    private let collectionView: UICollectionView = {
        let layout = TimelineFlowLayout()
        layout.minimumLineSpacing = 0
        layout.sectionInset = .zero
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()

    init(model: ConversationTimelineModel, actions: TimelineBubbleActions) {
        self.model = model
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyConversationBackground()
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInset.top = headerInset
        collectionView.verticalScrollIndicatorInsets.top = headerInset
        collectionView.register(TimelineCollectionViewCell.self, forCellWithReuseIdentifier: "timeline")
        measurer = TimelineRowMeasurer(parent: self)
        cancellable = model.updates.sink { [weak self] in self?.receive($0) }
    }

    private func applyConversationBackground() {
        let color = UIColor(ChahuaTheme.conversationBackground(for: colorScheme))
        view.backgroundColor = color
        collectionView.backgroundColor = color
    }

    private var currentGeometry: Geometry {
        .init(size: collectionView.bounds.size, insets: collectionView.adjustedContentInset)
    }

    private var availableRowWidth: CGFloat {
        currentGeometry.rowWidth
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !applying else { return }
        updateGeometryIfNeeded()
        installIfPossible(reason: .layout)
    }

    private func updateGeometryIfNeeded() {
        guard measurer != nil, availableRowWidth > 0, collectionView.bounds.height > 0,
              geometry != currentGeometry else { return }
        // UIKit may already have changed bounds/insets and invalidated its layout. Use the
        // position recorded in the previous geometry, not an anchor captured after reflow.
        let previousPosition = position ?? capturePosition()
        applying = true
        stopPhysicalAnimation()
        UIView.performWithoutAnimation {
            updateMeasurementsForGeometry()
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            restore(previousPosition)
            geometry = currentGeometry
            position = capturePosition()
        }
        needsPlacement = true
        animateFollowing = false
        applying = false
    }

    private func updateMeasurementsForGeometry() {
        guard geometry != currentGeometry else { return }
        let widthChanged = geometry?.rowWidth != availableRowWidth
        if widthChanged { measurer.invalidateAll() }
        // Height-only changes affect media bounds, not text. Offscreen measurements
        // validate their viewport context when requested; retain text height caches.
        let paths = collectionView.indexPathsForVisibleItems.filter { path in
            guard !widthChanged else { return true }
            guard rows.indices.contains(path.item), case .message(let message) = rows[path.item] else { return false }
            return !(message.entry.remoteMessage?.attachments.isEmpty ?? true)
        }
        if !paths.isEmpty { collectionView.reconfigureItems(at: paths) }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "timeline", for: indexPath) as! TimelineCollectionViewCell
        let row = rows[indexPath.item]
        cell.attach(to: self)
        cell.hosting.rootView = TimelineBubbleView(row: row, context: rowContext(for: row), actions: actions, mediaContext: mediaContext)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? TimelineCollectionViewCell)?.attach(to: self)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? TimelineCollectionViewCell)?.detach()
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        // Flow layout can request metrics before the parent's viewDidLayoutSubviews runs.
        let width = availableRowWidth
        return .init(width: width, height: measurer.height(for: rows[indexPath.item], width: width, context: rowContext(for: rows[indexPath.item])))
    }

    private func rowContext(for row: TimelineRow) -> TimelineRowContext {
        let hasMedia: Bool
        if case .message(let message) = row {
            hasMedia = !(message.entry.remoteMessage?.attachments.isEmpty ?? true)
        } else {
            hasMedia = false
        }
        return .init(
            isHighlighted: row.id == highlightedRowID,
            viewportSize: hasMedia ? CGSize(width: currentGeometry.rowWidth, height: currentGeometry.size.height) : .zero,
            currentUserID: model.currentUserID,
            isThreadTimeline: model.threadID != nil
        )
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrolling = true
        activeRequest = nil
        desiredRequest = nil
        stopPhysicalAnimation()
        model.userScrollBegan()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applying, geometry == currentGeometry else { return }
        position = capturePosition()
        // Geometry is settled even while the reader is moving. Prefetch during the
        // gesture/deceleration, not only after scrolling has come to a complete stop.
        reportViewport(reason: userScrolling ? .user : .layout)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        userScrolling = false
        installIfPossible(reason: .user)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        userScrolling = false
        installIfPossible(reason: .user)
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        view.setNeedsLayout()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // UIKit's callback has no request identity. An interrupted animation must not
        // complete a newer navigation: only the currently owned, reached target can finish.
        guard !applying, !userScrolling, !scrollView.isDragging, !scrollView.isDecelerating,
              let animation = scrollAnimation, geometry == currentGeometry,
              abs(scrollView.contentOffset.y - animation.targetY) <= 0.5,
              activeRequest?.id == animation.requestID else { return }
        scrollAnimation = nil
        if let id = animation.requestID {
            finishRequest(id: id)
        }
        installIfPossible()
    }

    private func receive(_ snapshot: TimelineHostSnapshot) {
        // A subscriber can synchronously publish another snapshot before this subscriber
        // receives the outer send. The subject's current value also resolves same-revision
        // acknowledgement/cancellation ordering without resurrecting the outer intent.
        let current = model.updates.value
        let newest = current.revision >= snapshot.revision ? current : snapshot
        guard newest.revision >= installedRevision,
              newest.revision >= (latestSnapshot?.revision ?? -1) else { return }
        latestSnapshot = newest
        installIfPossible()
    }

    private func installIfPossible(reason: TimelineViewportChangeReason = .programmatic) {
        guard !applying, !draining, measurer != nil,
              availableRowWidth > 0, collectionView.bounds.height > 0 else { return }
        draining = true
        repeat {
            if let snapshot = latestSnapshot {
                latestSnapshot = nil
                desiredRequest = snapshot.pendingScroll
                if installedRevision != snapshot.revision || installedWindowRevision != snapshot.windowRevision {
                    installRows(snapshot)
                }
                if applying { break }
                continue
            }
            applyScrollIntent()
            if latestSnapshot == nil { break }
        } while !applying
        draining = false
        guard !applying else { return }
        refreshHighlightIfNeeded()
        reportViewport(reason: reason)
    }

    private func installRows(_ snapshot: TimelineHostSnapshot) {
        applying = true
        stopPhysicalAnimation()
        collectionView.layoutIfNeeded()
        let previousPosition = geometry == currentGeometry ? capturePosition() : (position ?? capturePosition())
        let reset = installedWindowRevision != snapshot.windowRevision || installedRevision < 0
        let change = reset ? TimelineChange.reset : TimelineChange.compute(from: rows, to: snapshot.rows)
        let removed = Set(rows.map(\.id)).subtracting(Set(snapshot.rows.map(\.id)))
        measurer.remove(removed)

        UIView.performWithoutAnimation {
            collectionView.layoutIfNeeded()
            switch change {
            case .reset:
                rows = snapshot.rows
                collectionView.reloadData()
                finishInstalling(snapshot, reloads: [], position: previousPosition)
                completeInstallation()
            case .incremental(let removals, let insertions, let reloads):
                if removals.isEmpty && insertions.isEmpty {
                    rows = snapshot.rows
                    finishInstalling(snapshot, reloads: reloads, position: previousPosition)
                    completeInstallation()
                } else {
                    // UIKit may deliver even a nonanimated batch completion later. Settle
                    // the reader's geometry before returning, but serialize new batches
                    // until both layout and the native completion have finished.
                    var batchCompleted = false
                    var layoutCompleted = false
                    collectionView.performBatchUpdates {
                        self.rows = snapshot.rows
                        self.collectionView.deleteItems(at: removals.map { .init(item: $0, section: 0) })
                        self.collectionView.insertItems(at: insertions.map { .init(item: $0, section: 0) })
                    } completion: { [weak self] _ in
                        batchCompleted = true
                        if layoutCompleted { self?.completeInstallation() }
                    }
                    finishInstalling(snapshot, reloads: reloads, position: previousPosition)
                    layoutCompleted = true
                    if batchCompleted { completeInstallation() }
                }
            }
        }
    }

    private func finishInstalling(_ snapshot: TimelineHostSnapshot, reloads: IndexSet, position previousPosition: Position) {
        // Anchor compensation belongs to the same display transaction as the row
        // mutation, not the potentially delayed batch-completion callback.
        UIView.performWithoutAnimation {
            if !reloads.isEmpty {
                collectionView.reconfigureItems(at: reloads.map { .init(item: $0, section: 0) })
            }
            updateMeasurementsForGeometry()
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            restore(previousPosition)
            geometry = currentGeometry
            position = capturePosition()
        }
        installedRevision = snapshot.revision
        installedWindowRevision = snapshot.windowRevision
        needsPlacement = true
        animateFollowing = snapshot.animateFollowing
    }

    private func completeInstallation() {
        applying = false
        // Defer the drain until the initiating performWithoutAnimation scope has returned,
        // including when UIKit invokes its completion synchronously. Only scrolling animates.
        if !draining {
            updateGeometryIfNeeded()
            installIfPossible()
        }
    }

    private func applyScrollIntent() {
        let retarget = needsPlacement
        needsPlacement = false
        let shouldAnimateFollowing = animateFollowing
        animateFollowing = false
        applying = true
        defer { applying = false }

        if let request = desiredRequest {
            if activeRequest?.id != request.id {
                activeRequest = nil
                stopPhysicalAnimation()
                guard request.id > lastStartedRequestID else { return }
                lastStartedRequestID = request.id
                activeRequest = request
                userScrolling = false
                if case .reveal(let id, _, let highlight) = request.intent, highlight,
                   rows.contains(where: { $0.id == id }) {
                    highlightRow(id)
                }
            }
            guard retarget || scrollAnimation == nil else { return }
            execute(request)
        } else {
            if activeRequest != nil {
                activeRequest = nil
                stopPhysicalAnimation()
            }
            if retarget, model.state.live.followsLatest, model.isAtLiveEdge {
                scroll(to: bottomOffset, animated: shouldAnimateFollowing, requestID: nil)
            }
        }
    }

    private func visibleItems() -> [UICollectionViewLayoutAttributes] {
        let insets = collectionView.adjustedContentInset
        let visible = CGRect(
            x: collectionView.contentOffset.x + insets.left,
            y: collectionView.contentOffset.y + insets.top,
            width: availableRowWidth,
            height: max(0, collectionView.bounds.height - insets.top - insets.bottom)
        )
        // Visible cells can lag an offset change until the next display pass. Layout
        // geometry identifies the reader's message even if its cell is not installed yet.
        return (collectionView.collectionViewLayout.layoutAttributesForElements(in: visible) ?? []).filter {
            $0.representedElementCategory == .cell && rows.indices.contains($0.indexPath.item)
                && $0.frame.intersects(visible)
        }
    }

    private func capturePosition() -> Position {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let message = visibleItems().lazy.filter {
            if case .message = self.rows[$0.indexPath.item] { return true }
            return false
        }.min(by: { $0.indexPath < $1.indexPath })
        if let message {
            return .init(messageID: rows[message.indexPath.item].id, messageOffset: message.frame.minY - top, top: top)
        }
        return .init(messageID: nil, messageOffset: 0, top: top)
    }

    private func restore(_ position: Position) {
        var top = position.top
        if let id = position.messageID, let index = rows.firstIndex(where: { $0.id == id }),
           let frame = collectionView.layoutAttributesForItem(at: .init(item: index, section: 0))?.frame {
            top = frame.minY - position.messageOffset
        }
        // If the message was removed, retain the old document position within the new limits.
        let y = clampedOffset(top - collectionView.adjustedContentInset.top)
        collectionView.setContentOffset(.init(x: -collectionView.adjustedContentInset.left, y: y), animated: false)
    }

    private var bottomOffset: CGFloat {
        max(-collectionView.adjustedContentInset.top,
            collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
    }

    private func clampedOffset(_ y: CGFloat) -> CGFloat {
        min(bottomOffset, max(-collectionView.adjustedContentInset.top, y))
    }

    private func execute(_ request: TimelineScrollRequest) {
        switch request.intent {
        case .bottom(let animated):
            scroll(to: bottomOffset, animated: animated, requestID: request.id)
        case .reveal(let id, let animated, _):
            guard let index = rows.firstIndex(where: { $0.id == id }),
                  let frame = collectionView.layoutAttributesForItem(at: .init(item: index, section: 0))?.frame else {
                finishRequest(id: request.id)
                return
            }
            let insets = collectionView.adjustedContentInset
            let height = max(0, collectionView.bounds.height - insets.top - insets.bottom)
            scroll(to: frame.midY - height / 2 - insets.top, animated: animated, requestID: request.id)
        }
    }

    private func scroll(to y: CGFloat, animated: Bool, requestID: Int?) {
        stopPhysicalAnimation()
        let target = clampedOffset(y)
        let shouldAnimate = animated && abs(collectionView.contentOffset.y - target) > 0.5
        if shouldAnimate {
            scrollAnimation = .init(targetY: target, requestID: requestID)
        }
        collectionView.setContentOffset(.init(x: -collectionView.adjustedContentInset.left, y: target), animated: shouldAnimate)
        if !shouldAnimate || abs(collectionView.contentOffset.y - target) <= 0.5 {
            scrollAnimation = nil
            if let requestID {
                finishRequest(id: requestID)
            }
        }
    }

    private func stopPhysicalAnimation() {
        guard scrollAnimation != nil else { return }
        scrollAnimation = nil
        // A nonanimated offset assignment stops UIScrollView's physical animation. Clear
        // ownership first so any callback caused by interruption cannot acknowledge it.
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
    }

    private func finishRequest(id: Int) {
        guard activeRequest?.id == id else { return }
        activeRequest = nil
        model.scrollRequestDidFinish(id: id)
    }

    private func highlightRow(_ id: TimelineRowID) {
        highlightedRowID = id
        highlightNeedsRefresh = true
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard let self, self.highlightedRowID == id else { return }
            self.highlightedRowID = nil
            self.highlightNeedsRefresh = true
            self.refreshHighlightIfNeeded()
        }
    }

    private func refreshHighlightIfNeeded() {
        guard highlightNeedsRefresh, !applying else { return }
        highlightNeedsRefresh = false
        applying = true
        UIView.performWithoutAnimation {
            collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
            collectionView.layoutIfNeeded()
        }
        applying = false
    }

    private func reportViewport(reason: TimelineViewportChangeReason) {
        guard !applying, !draining, latestSnapshot == nil, scrollAnimation == nil,
              reason == .user || (!userScrolling && !collectionView.isDragging && !collectionView.isDecelerating),
              installedRevision >= 0, geometry == currentGeometry else { return }
        position = capturePosition()
        let visible = visibleItems().map(\.indexPath.item)
        let top = max(0, collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
        let height = max(0, collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom)
        model.viewportDidChange(.init(
            firstVisibleIndex: visible.min(),
            lastVisibleIndex: visible.max(),
            distanceToTop: top,
            distanceToBottom: max(0, collectionView.contentSize.height - top - height),
            height: height
        ), reason: reason, revision: installedRevision)
    }
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
