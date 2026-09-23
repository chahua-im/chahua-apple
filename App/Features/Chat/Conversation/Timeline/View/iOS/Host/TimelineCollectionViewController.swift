#if os(iOS)
    import ChahuaAPI
    import Combine
    import SwiftUI
    import UIKit

    @MainActor
    final class TimelineCollectionViewController: UIViewController, UICollectionViewDataSource,
        UICollectionViewDelegateFlowLayout
    {
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
                guard !actions.hasSameRendering(as: oldValue) else { return }
                rowActions = makeRowActions()
                guard isViewLoaded else { return }
                if actions.currentUserProfile != oldValue.currentUserProfile {
                    profileNeedsPreparation = true
                    latestSnapshot = model.updates.value
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
        var composerInset: CGFloat = 0 {
            didSet {
                guard composerInset != oldValue, isViewLoaded else { return }
                collectionView.contentInset.bottom = composerInset
                collectionView.verticalScrollIndicatorInsets.bottom = composerInset
                view.setNeedsLayout()
            }
        }
        private let layoutCache = TimelineLayoutCache()
        private var presentations: [TimelineRowID: TimelineRowPresentation] = [:]
        private var installedLayouts: [TimelineRowID: TimelineRowLayout] = [:]
        private var preparation: TimelineLayoutPreparation?
        private var layoutEnvironment: TimelineLayoutEnvironment?
        private var displayScheduler: TimelineDisplayScheduler!
        private var profileNeedsPreparation = false
        private var unsettledRows: Set<TimelineRowID> = []
        private var heightChanges = IndexSet()
        private var completingSnapshot: TimelineHostSnapshot?
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
            registerForTraitChanges([
                UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self,
                UITraitLayoutDirection.self,
            ]) { (controller: TimelineCollectionViewController, _: UITraitCollection) in
                controller.requestDisplayUpdate()
            }
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
            // SwiftUI supplies the header/composer clearance explicitly, including the
            // system top inset when drawing under navigation chrome. Do not add it twice.
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.contentInset.top = headerInset
            collectionView.verticalScrollIndicatorInsets.top = headerInset
            collectionView.contentInset.bottom = composerInset
            collectionView.verticalScrollIndicatorInsets.bottom = composerInset
            collectionView.register(
                TimelineCollectionViewCell.self, forCellWithReuseIdentifier: "timeline")
            displayScheduler = TimelineDisplayScheduler(view: view)
            cancellable = model.updates.sink { [weak self] in self?.receive($0) }
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged),
                name: NSLocale.currentLocaleDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged), name: .NSSystemTimeZoneDidChange,
                object: nil)
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
            requestDisplayUpdate()
            if installedRevision < 0 { displayScheduler.flush() }
        }

        private func updateGeometryIfNeeded() {
            guard availableRowWidth.isFinite, availableRowWidth > 0,
                collectionView.bounds.height > 0,
                geometry != currentGeometry || layoutEnvironment != currentEnvironment
            else { return }
            let previousPosition = position ?? capturePosition()
            let environmentChanged = layoutEnvironment != currentEnvironment
            applying = true
            stopPhysicalAnimation()
            UIView.performWithoutAnimation {
                if environmentChanged {
                    layoutEnvironment = currentEnvironment
                    unsettledRows = Set(rows.map(\.id))
                    for index in visibleRowIndexes {
                        let oldHeight = installedLayouts[rows[index].id]?.size.height
                        let layout = exactLayout(for: rows[index])
                        if oldHeight != layout.size.height { heightChanges.insert(index) }
                    }
                    invalidateChangedHeights()
                    refreshVisibleRoots()
                }
                collectionView.layoutIfNeeded()
                restore(previousPosition)
                geometry = currentGeometry
                settleVisibleRows(preserving: previousPosition)
                position = capturePosition()
            }
            needsPlacement = true
            animateFollowing = false
            applying = false
            if !unsettledRows.isEmpty { requestDisplayUpdate() }
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
            -> Int
        {
            rows.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
            -> UICollectionViewCell
        {
            let cell =
                collectionView.dequeueReusableCell(withReuseIdentifier: "timeline", for: indexPath)
                as! TimelineCollectionViewCell
            let row = rows[indexPath.item]
            bind(cell, row: row)
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            guard let cell = cell as? TimelineCollectionViewCell else { return }
            bind(cell, row: rows[indexPath.item])
            cell.rowView.setVisible(true)
            guard !applying, !heightChanges.isEmpty else { return }
            let previousPosition = capturePosition()
            applying = true
            UIView.performWithoutAnimation {
                invalidateChangedHeights()
                collectionView.layoutIfNeeded()
                restore(previousPosition)
            }
            settleVisibleRows(preserving: previousPosition)
            position = capturePosition()
            applying = false
        }

        func collectionView(
            _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            (cell as? TimelineCollectionViewCell)?.rowView.clear()
        }

        func collectionView(
            _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            // Flow layout can request metrics before the parent's viewDidLayoutSubviews runs.
            let width = availableRowWidth
            let row = rows[indexPath.item]
            let layout =
                unsettledRows.contains(row.id)
                ? installedLayouts[row.id] ?? exactLayout(for: row) : exactLayout(for: row)
            return .init(width: width, height: layout.size.height)
        }

        private func rowContext(for row: TimelineRow) -> TimelineRowContext {
            .init(
                isHighlighted: row.id == highlightedRowID,
                currentUserID: model.currentUserID,
                isThreadTimeline: model.threadID != nil
            )
        }

        private var currentEnvironment: TimelineLayoutEnvironment {
            let traits = view.traitCollection
            return .current(
                timelineWidth: availableRowWidth, displayScale: traits.displayScale,
                bodySize: UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
                    .pointSize,
                captionSize: UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
                    .pointSize,
                caption2Size: UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits)
                    .pointSize,
                avatarSize: UIFontMetrics(forTextStyle: .body).scaledValue(
                    for: 36, compatibleWith: traits),
                layoutDirection: view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                    ? .rightToLeft : .leftToRight)
        }

        private func exactLayout(for row: TimelineRow) -> TimelineRowLayout {
            let environment = layoutEnvironment ?? currentEnvironment
            guard environment.timelineWidth.isFinite, environment.timelineWidth > 0 else {
                return installedLayouts[row.id] ?? .empty
            }
            if let presentation = presentations[row.id], presentation.environment == environment,
                presentation.row == row, let layout = installedLayouts[row.id]
            {
                unsettledRows.remove(row.id)
                return layout
            }
            let presentation = TimelineRowPresentation.make(
                row: row, currentUserProfile: actions.currentUserProfile,
                currentUserID: model.currentUserID, isThreadTimeline: model.threadID != nil,
                environment: environment)
            let layout = layoutCache.layout(for: presentation, environment: environment)
            presentations[row.id] = presentation
            installedLayouts[row.id] = layout
            unsettledRows.remove(row.id)
            return layout
        }

        private func bind(_ cell: TimelineCollectionViewCell, row: TimelineRow) {
            let oldHeight = installedLayouts[row.id]?.size.height
            let layout = exactLayout(for: row)
            if oldHeight != layout.size.height,
                let index = rows.firstIndex(where: { $0.id == row.id })
            {
                heightChanges.insert(index)
                requestDisplayUpdate()
            }
            guard let presentation = presentations[row.id] else { return }
            cell.rowView.bind(
                .init(
                    presentation: presentation, layout: layout, context: rowContext(for: row),
                    actions: rowActions, mediaContext: mediaContext))
        }

        private func refreshVisibleRoots() {
            for path in collectionView.indexPathsForVisibleItems {
                guard rows.indices.contains(path.item),
                    let cell = collectionView.cellForItem(at: path) as? TimelineCollectionViewCell
                else { continue }
                bind(cell, row: rows[path.item])
            }
        }

        private var visibleRowIndexes: IndexSet {
            IndexSet(visibleItems().map(\.indexPath.item))
        }

        private func invalidateChangedHeights() {
            guard !heightChanges.isEmpty else { return }
            // FlowLayout's item invalidation can update a cell's height while retaining
            // following item positions. Rebuild the layout so the whole suffix reflows;
            // delegate sizes still come from our prepared row-layout cache.
            heightChanges.removeAll()
            collectionView.collectionViewLayout.invalidateLayout()
        }

        private func requestDisplayUpdate() {
            displayScheduler?.request { [weak self] in
                guard let self, !self.applying else { return }
                self.updateGeometryIfNeeded()
                self.installIfPossible()
                self.settleNextHeightBatch()
            }
        }

        private func settleVisibleRows(preserving position: Position) {
            guard !unsettledRows.isEmpty || !heightChanges.isEmpty else { return }
            while true {
                for item in visibleItems() {
                    let layout = exactLayout(for: rows[item.indexPath.item])
                    if item.frame.height != layout.size.height {
                        heightChanges.insert(item.indexPath.item)
                    }
                }
                refreshVisibleRoots()
                guard !heightChanges.isEmpty else { return }
                UIView.performWithoutAnimation {
                    invalidateChangedHeights()
                    collectionView.layoutIfNeeded()
                    if model.state.live.followsLatest && model.isAtLiveEdge {
                        collectionView.setContentOffset(
                            .init(x: -collectionView.adjustedContentInset.left, y: bottomOffset),
                            animated: false)
                    } else {
                        restore(position)
                    }
                }
            }
        }

        @objc private func environmentChanged() {
            preparation = nil
            requestDisplayUpdate()
        }

        deinit {
            highlightTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        private func settleNextHeightBatch() {
            guard !applying, !draining, scrollAnimation == nil, latestSnapshot == nil,
                layoutEnvironment == currentEnvironment,
                !unsettledRows.isEmpty || !heightChanges.isEmpty
            else { return }
            let previousPosition = position ?? capturePosition()
            let overscan = unobscuredViewport.insetBy(dx: 0, dy: -unobscuredViewport.height)
            let priority =
                (collectionView.collectionViewLayout.layoutAttributesForElements(in: overscan) ?? [])
                .filter {
                    $0.representedElementCategory == .cell
                        && rows.indices.contains($0.indexPath.item)
                }
                .map(\.indexPath.item)
            let prioritySet = Set(priority)
            let candidates =
                priority
                + rows.indices.filter {
                    !prioritySet.contains($0) && unsettledRows.contains(rows[$0].id)
                }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.004
            var count = 0
            applying = true
            for index in candidates where unsettledRows.contains(rows[index].id) {
                let previousHeight = installedLayouts[rows[index].id]?.size.height
                let height = exactLayout(for: rows[index]).size.height
                if previousHeight != height { heightChanges.insert(index) }
                count += 1
                if count == 32 || ProcessInfo.processInfo.systemUptime >= deadline { break }
            }
            UIView.performWithoutAnimation {
                invalidateChangedHeights()
                collectionView.layoutIfNeeded()
                refreshVisibleRoots()
                if model.state.live.followsLatest && model.isAtLiveEdge {
                    collectionView.setContentOffset(
                        .init(x: -collectionView.adjustedContentInset.left, y: bottomOffset),
                        animated: false)
                } else {
                    restore(previousPosition)
                }
            }
            settleVisibleRows(preserving: previousPosition)
            position = capturePosition()
            applying = false
            if !unsettledRows.isEmpty || !heightChanges.isEmpty { requestDisplayUpdate() }
            reportViewport(reason: .layout)
        }

        private func makeRowActions() -> TimelineBubbleActions {
            .init(
                openMedia: actions.openMedia == nil
                    ? nil : { [weak self] in self?.actions.openMedia?($0) },
                openSticker: actions.openSticker == nil
                    ? nil : { [weak self] in self?.actions.openSticker?($0) },
                openReply: actions.openReply == nil
                    ? nil : { [weak self] in self?.actions.openReply?($0) },
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
                openContextMenu: actions.openContextMenu == nil
                    ? nil : { [weak self] in self?.actions.openContextMenu?($0, $1) },
                toggleReaction: actions.toggleReaction == nil
                    ? nil : { [weak self] in self?.actions.toggleReaction?($0, $1) },
                pendingReactionMessageIDs: actions.pendingReactionMessageIDs,
                currentUserProfile: actions.currentUserProfile,
                interactionContext: actions.interactionContext,
                modifiablePendingMessageIDs: actions.modifiablePendingMessageIDs,
                blockPendingMessage: actions.blockPendingMessage == nil
                    ? nil : { [weak self] in self?.actions.blockPendingMessage?($0) },
                revokePendingMessage: actions.revokePendingMessage == nil
                    ? nil : { [weak self] in self?.actions.revokePendingMessage?($0) }
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
            // A tall row can stay installed while individual images enter/leave the
            // viewport. Refresh native media visibility without rebinding its content.
            for case let cell as TimelineCollectionViewCell in collectionView.visibleCells {
                cell.rowView.setVisible(true)
            }
            position = capturePosition()
            // Geometry is settled even while the reader is moving. Prefetch during the
            if !unsettledRows.isEmpty { requestDisplayUpdate() }
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
                activeRequest?.id == animation.requestID
            else { return }
            scrollAnimation = nil
            applying = true
            settleVisibleRows(preserving: capturePosition())
            applying = false
            if let id = animation.requestID {
                finishRequest(id: id)
            }
            requestDisplayUpdate()
        }

        private func receive(_ snapshot: TimelineHostSnapshot) {
            // A subscriber can synchronously publish another snapshot before this subscriber
            // receives the outer send. The subject's current value also resolves same-revision
            // acknowledgement/cancellation ordering without resurrecting the outer intent.
            let current = model.updates.value
            let newest = current.revision >= snapshot.revision ? current : snapshot
            guard newest.revision >= installedRevision,
                newest.revision >= (latestSnapshot?.revision ?? -1)
            else { return }
            if let old = preparation,
                old.snapshot.revision != newest.revision
                    || old.snapshot.windowRevision != newest.windowRevision
            {
                let retained = Set(rows.map(\.id)).union(newest.rows.map(\.id))
                layoutCache.remove(Set(old.snapshot.rows.map(\.id)).subtracting(retained))
                preparation = nil
            }
            latestSnapshot = newest
            requestDisplayUpdate()
            if installedRevision < 0 || newest.pendingScroll != nil { displayScheduler?.flush() }
        }

        private func installIfPossible(reason: TimelineViewportChangeReason = .programmatic) {
            guard !applying, !draining, displayScheduler != nil,
                availableRowWidth.isFinite, availableRowWidth > 0, collectionView.bounds.height > 0
            else { return }
            draining = true
            repeat {
                if let snapshot = latestSnapshot {
                    let needsRows =
                        installedRevision != snapshot.revision
                        || installedWindowRevision != snapshot.windowRevision
                        || profileNeedsPreparation
                    if needsRows {
                        let environment = currentEnvironment
                        if preparation?.snapshot.revision != snapshot.revision
                            || preparation?.snapshot.windowRevision != snapshot.windowRevision
                            || preparation?.environment != environment
                            || preparation?.profile != actions.currentUserProfile
                        {
                            preparation = TimelineLayoutPreparation(
                                snapshot: snapshot, environment: environment,
                                profile: actions.currentUserProfile)
                        }
                        guard let work = preparation else { break }
                        guard
                            work.advance(
                                cache: layoutCache, currentUserID: model.currentUserID,
                                isThreadTimeline: model.threadID != nil)
                        else {
                            requestDisplayUpdate()
                            break
                        }
                        guard model.updates.value.revision == work.snapshot.revision,
                            model.updates.value.windowRevision == work.snapshot.windowRevision,
                            currentEnvironment == work.environment
                        else {
                            preparation = nil
                            latestSnapshot = model.updates.value
                            requestDisplayUpdate()
                            break
                        }
                    }
                    latestSnapshot = nil
                    desiredRequest = model.updates.value.pendingScroll
                    if needsRows, let work = preparation {
                        installRows(snapshot, prepared: work)
                        preparation = nil
                        profileNeedsPreparation = false
                    }
                    if applying { break }
                    if needsRows {
                        if latestSnapshot == nil {
                            applyScrollIntent()
                        } else {
                            requestDisplayUpdate()
                        }
                        break
                    }
                    continue
                }
                applyScrollIntent()
                if latestSnapshot == nil { break }
                if latestSnapshot != nil {
                    requestDisplayUpdate()
                    break
                }
            } while !applying
            draining = false
            guard !applying else { return }
            refreshHighlightIfNeeded()
            reportViewport(reason: reason)
        }

        private func installRows(
            _ snapshot: TimelineHostSnapshot, prepared: TimelineLayoutPreparation
        ) {
            applying = true
            stopPhysicalAnimation()
            collectionView.layoutIfNeeded()
            let previousPosition =
                geometry == currentGeometry ? capturePosition() : (position ?? capturePosition())
            heightChanges.removeAll()
            for (index, row) in snapshot.rows.enumerated() {
                if installedLayouts[row.id]?.size.height != prepared.layouts[row.id]?.size.height {
                    heightChanges.insert(index)
                }
            }
            presentations = prepared.presentations
            installedLayouts = prepared.layouts
            layoutEnvironment = prepared.environment
            unsettledRows.removeAll()
            let reset = installedWindowRevision != snapshot.windowRevision || installedRevision < 0
            let change =
                reset ? TimelineChange.reset : TimelineChange.compute(from: rows, to: snapshot.rows)
            let removed = Set(rows.map(\.id)).subtracting(Set(snapshot.rows.map(\.id)))
            layoutCache.remove(removed)

            UIView.performWithoutAnimation {
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
                            self.collectionView.deleteItems(
                                at: removals.map { .init(item: $0, section: 0) })
                            self.collectionView.insertItems(
                                at: insertions.map { .init(item: $0, section: 0) })
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

        private func finishInstalling(
            _ snapshot: TimelineHostSnapshot, reloads: IndexSet, position previousPosition: Position
        ) {
            // Anchor compensation belongs to the same display transaction as the row
            // mutation, not the potentially delayed batch-completion callback.
            UIView.performWithoutAnimation {
                refreshVisibleRoots()
                invalidateChangedHeights()
                collectionView.layoutIfNeeded()
                restore(previousPosition)
                geometry = currentGeometry
                position = capturePosition()
            }
            completingSnapshot = snapshot
            needsPlacement = true
            animateFollowing = snapshot.animateFollowing
        }

        private func completeInstallation() {
            applying = false
            if let snapshot = completingSnapshot {
                installedRevision = snapshot.revision
                installedWindowRevision = snapshot.windowRevision
                completingSnapshot = nil
            }
            // Defer the drain until the initiating performWithoutAnimation scope has returned,
            // including when UIKit invokes its completion synchronously. Only scrolling animates.
            if !draining {
                requestDisplayUpdate()
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
                        rows.contains(where: { $0.id == id })
                    {
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

        private var unobscuredViewport: CGRect {
            let insets = collectionView.adjustedContentInset
            return CGRect(
                x: collectionView.contentOffset.x + insets.left,
                y: collectionView.contentOffset.y + insets.top,
                width: availableRowWidth,
                height: max(0, collectionView.bounds.height - insets.top - insets.bottom)
            )
        }

        private func visibleItems() -> [UICollectionViewLayoutAttributes] {
            let visible = unobscuredViewport
            // Visible cells can lag an offset change until the next display pass. Layout
            // geometry identifies the reader's message even if its cell is not installed yet.
            return
                (collectionView.collectionViewLayout.layoutAttributesForElements(in: visible) ?? [])
                .filter {
                    $0.representedElementCategory == .cell
                        && rows.indices.contains($0.indexPath.item)
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
                return .init(
                    messageID: rows[message.indexPath.item].id,
                    messageOffset: message.frame.minY - top, top: top)
            }
            return .init(messageID: nil, messageOffset: 0, top: top)
        }

        private func restore(_ position: Position) {
            var top = position.top
            if let id = position.messageID, let index = rows.firstIndex(where: { $0.id == id }),
                let frame = collectionView.layoutAttributesForItem(
                    at: .init(item: index, section: 0))?.frame
            {
                top = frame.minY - position.messageOffset
            }
            // If the message was removed, retain the old document position within the new limits.
            let y = clampedOffset(top - collectionView.adjustedContentInset.top)
            collectionView.setContentOffset(
                .init(x: -collectionView.adjustedContentInset.left, y: y), animated: false)
        }

        private var bottomOffset: CGFloat {
            max(
                -collectionView.adjustedContentInset.top,
                collectionView.contentSize.height - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom)
        }

        private func clampedOffset(_ y: CGFloat) -> CGFloat {
            min(bottomOffset, max(-collectionView.adjustedContentInset.top, y))
        }

        private func execute(_ request: TimelineScrollRequest) {
            switch request.intent {
            case .bottom(let animated):
                if let index = rows.indices.last { prepareScrollTarget(index) }
                scroll(to: bottomOffset, animated: animated, requestID: request.id)
            case .reveal(let id, let animated, _), .readBoundary(let id, let animated):
                guard let index = rows.firstIndex(where: { $0.id == id }) else {
                    finishRequest(id: request.id)
                    return
                }
                prepareScrollTarget(index)
                guard
                    let frame = collectionView.layoutAttributesForItem(
                        at: .init(item: index, section: 0))?.frame
                else {
                    finishRequest(id: request.id)
                    return
                }
                let insets = collectionView.adjustedContentInset
                let height = max(0, collectionView.bounds.height - insets.top - insets.bottom)
                let target: CGFloat
                if case .readBoundary = request.intent {
                    target = frame.maxY - collectionView.bounds.height + insets.bottom
                } else {
                    target =
                        id == .unreadSeparator
                        ? frame.minY - insets.top : frame.midY - height / 2 - insets.top
                }
                scroll(to: target, animated: animated, requestID: request.id)
            }
        }

        private func prepareScrollTarget(_ index: Int) {
            let layout = exactLayout(for: rows[index])
            let path = IndexPath(item: index, section: 0)
            guard
                collectionView.layoutAttributesForItem(at: path)?.frame.height != layout.size.height
            else { return }
            heightChanges.insert(index)
            UIView.performWithoutAnimation {
                invalidateChangedHeights()
                collectionView.layoutIfNeeded()
            }
        }
        private func scroll(to y: CGFloat, animated: Bool, requestID: Int?) {
            stopPhysicalAnimation()
            let target = clampedOffset(y)
            let shouldAnimate = animated && abs(collectionView.contentOffset.y - target) > 0.5
            if shouldAnimate {
                scrollAnimation = .init(targetY: target, requestID: requestID)
            }
            collectionView.setContentOffset(
                .init(x: -collectionView.adjustedContentInset.left, y: target),
                animated: shouldAnimate)
            if !shouldAnimate || abs(collectionView.contentOffset.y - target) <= 0.5 {
                scrollAnimation = nil
                settleVisibleRows(preserving: capturePosition())
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
            guard activeRequest?.id == id, installedRevision == model.updates.value.revision,
                model.updates.value.pendingScroll?.id == id
            else { return }
            // Acknowledgement can synchronously change SwiftUI's header/composer geometry.
            // Save the reached target before publishing so that relayout cannot restore
            // the position from before this navigation.
            position = capturePosition()
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
                refreshVisibleRoots()
                collectionView.layoutIfNeeded()
            }
            applying = false
        }

        private func reportViewport(reason: TimelineViewportChangeReason) {
            guard !applying, !draining, latestSnapshot == nil, scrollAnimation == nil,
                reason == .user
                    || (!userScrolling && !collectionView.isDragging
                        && !collectionView.isDecelerating),
                installedRevision >= 0, installedRevision == model.updates.value.revision,
                geometry == currentGeometry, layoutEnvironment == currentEnvironment
            else { return }
            position = capturePosition()
            let visibleItems = visibleItems()
            let visible = visibleItems.map(\.indexPath.item)
            let unobscured = unobscuredViewport
            let fullyVisibleMessageIDs = visibleItems.sorted { $0.indexPath < $1.indexPath }
                .compactMap { item -> String? in
                    guard !unobscured.isEmpty, unobscured.contains(item.frame) else { return nil }
                    return rows[item.indexPath.item].messageID
                }
            let top = max(
                0, collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
            let height = max(
                0,
                collectionView.bounds.height - collectionView.adjustedContentInset.top
                    - collectionView.adjustedContentInset.bottom)
            model.viewportDidChange(
                .init(
                    firstVisibleIndex: visible.min(),
                    lastVisibleIndex: visible.max(),
                    distanceToTop: top,
                    distanceToBottom: max(0, collectionView.contentSize.height - top - height),
                    height: height,
                    fullyVisibleMessageIDs: fullyVisibleMessageIDs
                ), reason: reason, revision: installedRevision)
        }
    }

    private final class TimelineFlowLayout: UICollectionViewFlowLayout {
        override func invalidationContext(forBoundsChange newBounds: CGRect)
            -> UICollectionViewLayoutInvalidationContext
        {
            let context = super.invalidationContext(forBoundsChange: newBounds)
            if newBounds.width != collectionView?.bounds.width,
                let context = context as? UICollectionViewFlowLayoutInvalidationContext
            {
                context.invalidateFlowLayoutDelegateMetrics = true
            }
            return context
        }
    }

#endif
