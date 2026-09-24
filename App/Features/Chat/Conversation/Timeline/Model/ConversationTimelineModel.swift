import ChahuaAPI
import Combine
import Foundation

enum TimelineInitialPosition: Equatable {
    case liveEdge
    case message(String)
    case unread(after: String?)
}

@MainActor
final class ConversationTimelineModel: ObservableObject {
    static let pageSize: Int64 = 50
    static let nearbyRowDistance = 30
    static let pinnedToBottomTolerance: CGFloat = 24
    static let edgePrefetchScreens: CGFloat = 2

    let chatID: String
    let threadID: String?
    let currentUserID: Int32
    @Published private(set) var state = ConversationTimelineState()
    @Published private(set) var rows: [TimelineRow] = []
    @Published private(set) var bottomVisibleMessageDate: Date?
    var isAtLiveEdge: Bool { window.isAtLiveEdge }
    var jumpUnreadCount: Int64 { state.live.unreadCount }
    var showsJumpToLatest: Bool {
        state.content == .ready
            && (!isAtLiveEdge
                || (viewportRevision == snapshotRevision && !state.live.isPinnedToBottom))
    }
    let updates = CurrentValueSubject<TimelineHostSnapshot, Never>(
        .init(revision: 0, windowRevision: 0, rows: [], animateFollowing: false, pendingScroll: nil)
    )

    private let source: any TimelineMessageSource
    private let messageStore: ConversationMessageStore
    private let builder: TimelineRowsBuilder
    private let markRead: (@MainActor (String) async throws -> Void)?
    private var window = TimelineWindow()
    private var observation: AnyCancellable?
    private var deferredCreates: [ConversationMessageStableKey: MessageResponse] = [:]
    private var preHistoryAcknowledgementKeys: Set<ConversationMessageStableKey> = []
    private var deletedIDs: Set<String> = []
    private var snapshotTokens: Set<UUID> = []
    private var generation = 0
    private var snapshotRevision = 0
    private var windowRevision = 0
    private var scrollRequestID = 0
    private var pendingScroll: TimelineScrollRequest?
    private var lastProjection: ConversationProjection?
    private var lastViewport = TimelineViewport.empty
    @Published private(set) var viewportRevision: Int?
    private var visibleAnchorID: String?
    private var lastInitialPosition: TimelineInitialPosition = .liveEdge
    private var initialTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var olderTask: Task<Void, Never>?
    private var newerTask: Task<Void, Never>?
    // A committed pending publication invalidates the host's viewport revision before reveal runs.
    private var canReuseLatestWindowAfterPendingChange = false
    // The entry boundary is frozen until the next open, independent of read receipts.
    private var unreadBeforeMessageID: String?
    private var lastReadMessageID: String?
    private var readWatermark: (id: String, createdAt: Date)?
    private var readTrackingActive = false
    private var hasSentEntryRead = false
    private var readCandidateID: String?
    private var readCandidateMature = false
    private var readDwellTask: Task<Void, Never>?
    private var readSendTask: Task<Void, Never>?

    init(
        chatID: String, currentUserID: Int32, isGroupChat: Bool, source: any TimelineMessageSource,
        messageStore: ConversationMessageStore, threadID: String? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        markRead: (@MainActor (String) async throws -> Void)? = nil
    ) {
        self.chatID = chatID
        self.threadID = threadID
        self.currentUserID = currentUserID
        self.source = source
        self.messageStore = messageStore
        self.markRead = markRead
        builder = TimelineRowsBuilder(
            currentUserID: currentUserID, isGroupChat: isGroupChat, calendar: calendar)
        observeChanges()
        publish()
    }

    /// Unlike fixture-oriented loadInitial, every appearance requests a fresh entry window.
    func open(position: TimelineInitialPosition = .liveEdge) async {
        invalidateRequests()
        observeChanges()
        clearWindow()
        await loadInitial(position: position)
    }

    func close() {
        setReadTrackingActive(false)
        invalidateRequests()
        observation = nil
    }

    func loadInitial(position: TimelineInitialPosition = .liveEdge) async {
        guard state.content == .idle || state.content == .initialLoadFailed else { return }
        observeChanges()
        lastInitialPosition = position
        state.content = .loadingInitial
        publish()
        let requestGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == requestGeneration { initialTask = nil } }
            do {
                if case .unread(let after) = position {
                    try await loadUnreadEntry(after: after, generation: requestGeneration)
                    return
                }
                try await fetchSnapshot(
                    query: aroundQuery(for: position),
                    mode: .replace(latest: position == .liveEdge), generation: requestGeneration
                ) {
                    self.state.content = .ready
                    switch position {
                    case .liveEdge:
                        self.state.live.followsLatest = true
                        self.publish(position: .bottom(animated: false), reset: true)
                    case .message(let id):
                        self.state.live.followsLatest = false
                        if let rowID = self.rowID(forServerID: id) {
                            self.publish(
                                position: .reveal(rowID, animated: false, highlight: true),
                                reset: true)
                        } else {
                            self.state.repositionFailure = .message(id)
                            self.publish(position: .bottom(animated: false), reset: true)
                        }
                    case .unread:
                        break  // Resolved above, before publishing the initial window.
                    }
                }
            } catch is CancellationError {
                if generation == requestGeneration {
                    state.content = .idle
                    publish()
                }
            } catch {
                if generation == requestGeneration {
                    state.content = .initialLoadFailed
                    publish()
                }
            }
        }
        initialTask = task
        await task.value
    }

    func retryInitial() async { await loadInitial(position: lastInitialPosition) }

    private enum UnreadEntryError: Error { case stalledCursor }

    private func loadUnreadEntry(after lastReadID: String?, generation requestGeneration: Int)
        async throws
    {
        let query = lastReadID.map { aroundQuery(for: .message($0)) } ?? liveEdgeQuery
        var fetchedLatest = lastReadID == nil
        do {
            try await fetchSnapshot(
                query: query, mode: .replace(latest: lastReadID == nil),
                generation: requestGeneration
            ) {}
        } catch let error as APIError {
            guard lastReadID != nil else { throw error }
            switch error {
            case .http(status: 404, body: _), .invalidResponse(statusCode: 404):
                try await fetchSnapshot(
                    query: liveEdgeQuery, mode: .replace(latest: true),
                    generation: requestGeneration
                ) {}
                fetchedLatest = true
            default:
                throw error
            }
        }
        // Some servers return an empty around page for an unavailable target instead
        // of 404. That is not evidence that the conversation itself is empty.
        if !fetchedLatest, window.messages.isEmpty {
            try await fetchSnapshot(
                query: liveEdgeQuery, mode: .replace(latest: true), generation: requestGeneration
            ) {}
        }

        if let lastReadID, let index = window.index(ofServerID: lastReadID) {
            let boundary = window.messages[index]
            advanceReadWatermark(to: boundary)
            var cursors: Set<String> = []
            // An around page can end exactly at the read boundary.
            while window.messages.last?.id == lastReadID, let cursor = window.newerCursor {
                guard cursors.insert(cursor).inserted else { throw UnreadEntryError.stalledCursor }
                try await fetchSnapshot(
                    query: .init(after: cursor, max: Self.pageSize, threadID: threadID),
                    mode: .page(.newer), generation: requestGeneration
                ) {}
            }
            if let index = window.index(ofServerID: lastReadID), index + 1 < window.messages.count {
                unreadBeforeMessageID = window.messages[index + 1].id
            }
        } else {
            // No oldest-query exists. Follow opaque older cursors rather than inventing a
            // sentinel or treating the latest page as the beginning of unread history.
            var cursors: Set<String> = []
            while let cursor = window.olderCursor {
                guard cursors.insert(cursor).inserted else { throw UnreadEntryError.stalledCursor }
                try await fetchSnapshot(
                    query: .init(before: cursor, max: Self.pageSize, threadID: threadID),
                    mode: .seekOlder, generation: requestGeneration
                ) {}
            }
            unreadBeforeMessageID = window.messages.first?.id
        }
        state.content = .ready
        state.live.followsLatest = unreadBeforeMessageID == nil && window.isAtLiveEdge
        publish(
            position: unreadBeforeMessageID == nil
                ? .bottom(animated: false)
                : .reveal(.unreadSeparator, animated: false, highlight: false), reset: true)
    }

    /// Supply the current chat or thread's authoritative metadata, never the entry snapshot.
    /// Pending live arrivals affect availability, but are already included in this badge count.
    func updateReadState(unreadCount: Int64, lastReadMessageID: String?) {
        self.lastReadMessageID = lastReadMessageID
        let count = max(0, unreadCount)
        if state.live.unreadCount != count { state.live.unreadCount = count }
        if let lastReadMessageID, let index = window.index(ofServerID: lastReadMessageID) {
            advanceReadWatermark(to: window.messages[index])
        }
        updateReadCandidate()
    }

    func setReadTrackingActive(_ active: Bool) {
        guard readTrackingActive != active else { return }
        readTrackingActive = active
        cancelReadCandidate()
        if active {
            // Both hosts remeasure and report on every snapshot, even at the same revision.
            viewportRevision = nil
            updates.send(
                .init(
                    revision: snapshotRevision, windowRevision: windowRevision, rows: rows,
                    animateFollowing: false, pendingScroll: pendingScroll))
        } else {
            // A callback may ignore cancellation; retain the task until it completes so
            // reactivation can never issue overlapping writes.
            readSendTask?.cancel()
            viewportRevision = nil
        }
    }

    private func cancelReadCandidate() {
        readDwellTask?.cancel()
        readDwellTask = nil
        readCandidateID = nil
        readCandidateMature = false
    }

    private var visibleReadCandidate: MessageResponse? {
        guard readTrackingActive, markRead != nil, observation != nil,
            state.content == .ready, pendingScroll == nil, viewportRevision == snapshotRevision,
            lastViewport.isValid(forRowCount: rows.count),
            let first = lastViewport.firstVisibleIndex, let last = lastViewport.lastVisibleIndex,
            let candidateID = lastViewport.fullyVisibleMessageIDs.last
        else { return nil }
        for index in (first...last).reversed() {
            guard case .message(let row) = rows[index], let message = row.entry.remoteMessage,
                message.id == candidateID
            else { continue }
            // Every entry refreshes server read state from an actual visible row,
            // including historical entries. The endpoint and local watermark never regress.
            if !hasSentEntryRead { return message }
            guard isBeyondCurrentReadState(message) else { return nil }
            return isLaterThanWatermark(message) ? message : nil
        }
        return nil
    }

    private func isBeyondCurrentReadState(_ message: MessageResponse) -> Bool {
        guard let lastReadMessageID else { return true }
        guard message.id != lastReadMessageID else { return false }
        if let boundary = window.index(ofServerID: lastReadMessageID),
            let candidate = window.index(ofServerID: message.id)
        {
            return candidate > boundary
        }
        // Server snowflake IDs can establish order across disjoint windows. Opaque IDs
        // still use the loaded chronology/watermark, never lexicographic comparison.
        if let boundary = UInt64(lastReadMessageID), let candidate = UInt64(message.id) {
            return candidate > boundary
        }
        return true
    }

    private func isLaterThanWatermark(_ message: MessageResponse) -> Bool {
        // A missing/deleted entry cursor cannot establish a local baseline. The read
        // endpoint advances monotonically, so visibility can still submit a candidate.
        guard let readWatermark else { return true }
        guard message.id != readWatermark.id else { return false }
        if let boundary = window.index(ofServerID: readWatermark.id),
            let candidate = window.index(ofServerID: message.id)
        {
            return candidate > boundary
        }
        // Across disjoint windows, equal timestamps cannot establish an order.
        return message.createdAt > readWatermark.createdAt
    }

    private func advanceReadWatermark(to message: MessageResponse) {
        if isLaterThanWatermark(message) { readWatermark = (message.id, message.createdAt) }
    }

    private func updateReadCandidate() {
        guard let candidate = visibleReadCandidate else {
            cancelReadCandidate()
            return
        }
        guard readCandidateID != candidate.id else { return }
        cancelReadCandidate()
        readCandidateID = candidate.id
        if !hasSentEntryRead {
            readCandidateMature = true
            sendMatureReadCandidate()
            return
        }
        let requestGeneration = generation
        readDwellTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, generation == requestGeneration,
                readCandidateID == candidate.id, visibleReadCandidate?.id == candidate.id
            else { return }
            readDwellTask = nil
            readCandidateMature = true
            sendMatureReadCandidate()
        }
    }

    private func sendMatureReadCandidate() {
        guard readSendTask == nil, readCandidateMature, let markRead,
            let candidate = visibleReadCandidate, candidate.id == readCandidateID
        else { return }
        let requestGeneration = generation
        readSendTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard self?.generation == requestGeneration,
                    self?.readCandidateID == candidate.id,
                    self?.visibleReadCandidate?.id == candidate.id
                else { throw CancellationError() }
                self?.hasSentEntryRead = true
                try await markRead(candidate.id)
                if self?.generation == requestGeneration {
                    self?.advanceReadWatermark(to: candidate)
                }
            } catch {
                // A later viewport can retry; failures must not spin a write loop.
            }
            guard let self else { return }
            readSendTask = nil
            if !Task.isCancelled, generation == requestGeneration, readCandidateID == candidate.id {
                cancelReadCandidate()
            }
            sendMatureReadCandidate()
        }
    }

    func reconcileAfterReconnect() async {
        guard observation != nil else { return }
        if let initialTask {
            await initialTask.value
            return
        }
        if let recoveryTask {
            await awaitRecovery(recoveryTask, generation: generation)
            return
        }
        if state.content == .idle || state.content == .initialLoadFailed {
            await loadInitial()
            return
        }
        guard state.content == .ready else { return }
        let followsLatest = window.isAtLiveEdge && state.live.followsLatest
        let anchor = followsLatest ? nil : visibleRemoteAnchor
        invalidateRequests()
        state.reconciliationFailed = false
        let requestGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == requestGeneration { recoveryTask = nil } }
            do {
                try await fetchSnapshot(
                    query: anchor.map { self.aroundQuery(for: .message($0)) } ?? liveEdgeQuery,
                    mode: .replace(latest: anchor == nil), generation: requestGeneration
                ) {
                    self.state.reconciliationFailed = false
                    if let anchor {
                        self.state.live.followsLatest = false
                        let target =
                            self.rowID(forServerID: anchor)
                            ?? self.window.messages.first.flatMap { self.rowID(forServerID: $0.id) }
                        self.publish(
                            position: target.map { .reveal($0, animated: false, highlight: false) },
                            reset: true)
                    } else {
                        self.state.live.followsLatest = true
                        self.publish(position: .bottom(animated: false), reset: true)
                    }
                }
            } catch is CancellationError {
                // Navigation or closure owns the replacement state.
            } catch {
                if generation == requestGeneration { state.reconciliationFailed = true }
            }
        }
        recoveryTask = task
        await awaitRecovery(task, generation: requestGeneration)
    }

    private func awaitRecovery(_ task: Task<Void, Never>, generation requestGeneration: Int) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                guard let self, generation == requestGeneration, recoveryTask != nil else { return }
                invalidateRequests()
            }
        }
    }

    func userScrollBegan() {
        canReuseLatestWindowAfterPendingChange = false
        if state.live.followsLatest { state.live.followsLatest = false }
        let cancelledRequest = pendingScroll != nil
        pendingScroll = nil
        if recoveryTask != nil { invalidateRequests() }
        if case .repositioning(.liveEdge) = state.content {
            invalidateRequests()
            state.content = .ready
        }
        if cancelledRequest {
            updates.send(
                .init(
                    revision: snapshotRevision, windowRevision: windowRevision, rows: rows,
                    animateFollowing: false, pendingScroll: nil))
        }
    }

    func viewportDidChange(
        _ viewport: TimelineViewport, reason: TimelineViewportChangeReason, revision: Int
    ) {
        if revision == snapshotRevision, !viewport.isValid(forRowCount: rows.count) {
            cancelReadCandidate()
        }
        guard revision == snapshotRevision, viewport.isValid(forRowCount: rows.count) else {
            return
        }
        canReuseLatestWindowAfterPendingChange = false
        let previousAnchorID = visibleAnchorID
        lastViewport = viewport
        if viewportRevision != revision { viewportRevision = revision }
        visibleAnchorID = nil
        if let first = viewport.firstVisibleIndex, let last = viewport.lastVisibleIndex {
            for index in first...last where rows[index].messageID != nil {
                visibleAnchorID = rows[index].messageID
                break
            }
        }
        var bottomDate: Date?
        if let first = viewport.firstVisibleIndex, let last = viewport.lastVisibleIndex {
            for index in stride(from: last, through: first, by: -1) {
                if case .message(let message) = rows[index] {
                    bottomDate = message.entry.createdAt
                    break
                }
            }
        }
        if bottomVisibleMessageDate != bottomDate { bottomVisibleMessageDate = bottomDate }
        let pinned = viewport.distanceToBottom <= Self.pinnedToBottomTolerance
        var nextLive = state.live
        nextLive.isPinnedToBottom = pinned
        if reason == .user, let previousAnchorID, let visibleAnchorID,
            let previous = window.index(ofServerID: previousAnchorID),
            let current = window.index(ofServerID: visibleAnchorID), previous != current
        {
            nextLive.scrollsTowardNewer = current > previous
        }
        // A settled unread/reply reveal can reach the live bottom without a gesture.
        // Do not resume following while a pending navigation still owns the viewport.
        if pinned, isAtLiveEdge, pendingScroll == nil { nextLive.followsLatest = true }
        if nextLive != state.live { state.live = nextLive }
        updateReadCandidate()
        guard reason == .user, state.content == .ready, recoveryTask == nil else { return }
        let threshold = Self.edgePrefetchScreens * viewport.height
        if viewport.distanceToTop < threshold { loadEdge(.older) }
        if viewport.distanceToBottom < threshold { loadEdge(.newer) }
    }

    func scrollRequestDidFinish(id: Int) {
        guard pendingScroll?.id == id else { return }
        pendingScroll = nil
        updates.send(
            .init(
                revision: snapshotRevision, windowRevision: windowRevision, rows: rows,
                animateFollowing: false, pendingScroll: nil))
    }

    /// The unread divider is frozen at entry; this navigation uses the live read cursor.
    func jumpTowardLatest() async {
        guard state.content == .ready else { return }
        if threadID == nil, jumpUnreadCount > 0, let lastReadMessageID, !isAtOrBeyondReadBoundary {
            await jumpToMessage(lastReadMessageID, atReadBoundary: true)
        } else {
            await jumpToLiveEdge()
        }
    }

    private var isAtOrBeyondReadBoundary: Bool {
        guard let lastReadMessageID, let visibleID = lastViewport.fullyVisibleMessageIDs.last else {
            return false
        }
        if visibleID == lastReadMessageID { return true }
        if let visible = window.index(ofServerID: visibleID),
            let boundary = window.index(ofServerID: lastReadMessageID)
        {
            return visible >= boundary
        }
        if let visible = UInt64(visibleID), let boundary = UInt64(lastReadMessageID) {
            return visible >= boundary
        }
        if let visible = window.index(ofServerID: visibleID), let readWatermark,
            readWatermark.id == lastReadMessageID
        {
            return window.messages[visible].createdAt > readWatermark.createdAt
        }
        return false
    }

    func jumpToLiveEdge(animated: Bool = true) async {
        if recoveryTask != nil { invalidateRequests() }
        state.repositionFailure = nil
        state.reconciliationFailed = false
        if canReuseLatestWindow {
            state.live.followsLatest = true
            requestScroll(.bottom(animated: animated))
            return
        }
        if case .repositioning(.liveEdge) = state.content { return }
        invalidateRequests()
        state.content = .repositioning(.liveEdge)
        let requestGeneration = generation
        do {
            try await fetchSnapshot(
                query: liveEdgeQuery, mode: .replace(latest: true), generation: requestGeneration
            ) {
                state.content = .ready
                state.live.followsLatest = true
                publish(position: .bottom(animated: false), reset: true)
            }
        } catch is CancellationError {
            if generation == requestGeneration { state.content = .ready }
        } catch {
            if generation == requestGeneration {
                state.content = .ready
                state.repositionFailure = .liveEdge
            }
        }
    }

    func jumpToMessage(_ id: String, atReadBoundary: Bool = false) async {
        switch state.content {
        case .ready, .repositioning: break
        default: return
        }
        invalidateRequests()
        state.repositionFailure = nil
        state.content = .ready
        if let rowID = rowID(forServerID: id) {
            state.live.followsLatest = false
            requestScroll(
                atReadBoundary
                    ? .readBoundary(rowID, animated: true)
                    : .reveal(rowID, animated: true, highlight: true))
            return
        }
        state.content = .repositioning(.message(id))
        let requestGeneration = generation
        do {
            try await fetchSnapshot(
                query: aroundQuery(for: .message(id)), mode: .replace(latest: false),
                generation: requestGeneration, requiredMessageID: id
            ) {
                state.content = .ready
                state.live.followsLatest = false
                if let rowID = rowID(forServerID: id) {
                    publish(
                        position: atReadBoundary
                            ? .readBoundary(rowID, animated: false)
                            : .reveal(rowID, animated: false, highlight: true), reset: true)
                } else {
                    state.repositionFailure = .message(id)
                    publish(position: .bottom(animated: false), reset: true)
                }
            }
        } catch is CancellationError {
            if generation == requestGeneration { state.content = .ready }
        } catch {
            if generation == requestGeneration {
                state.content = .ready
                if atReadBoundary {
                    await jumpToLiveEdge()
                } else {
                    state.repositionFailure = .message(id)
                }
            }
        }
    }

    func dismissRepositionFailure() { state.repositionFailure = nil }

    // Reveal a locally available tail immediately. History networking must not
    // keep the composer submitting after its durable enqueue has completed.
    func revealLatestAfterSend() {
        let canReuse = canReuseLatestWindow || canReuseLatestWindowAfterPendingChange
        canReuseLatestWindowAfterPendingChange = false
        if state.content == .ready, canReuse {
            state.live.followsLatest = true
            publish(position: .bottom(animated: false))
            return
        }
        let requestGeneration = generation
        Task { [weak self] in
            guard let self, generation == requestGeneration else { return }
            if state.content == .ready || state.content == .repositioning(.liveEdge) {
                await jumpToLiveEdge(animated: false)
            } else if state.content == .idle || state.content == .initialLoadFailed {
                await loadInitial()
            }
        }
    }

    enum EdgeSide { case older, newer }
    func retryOlder() {
        state.older = .idle
        loadEdge(.older)
    }
    func retryNewer() {
        state.newer = .idle
        loadEdge(.newer)
    }

    private var canReuseLatestWindow: Bool {
        guard window.isAtLiveEdge, viewportRevision == snapshotRevision,
            lastViewport.isValid(forRowCount: rows.count), let last = lastViewport.lastVisibleIndex
        else { return false }
        return rows.indices.last.map { $0 - last <= Self.nearbyRowDistance } ?? true
    }

    private var visibleRemoteAnchor: String? {
        if let visibleAnchorID, window.index(ofServerID: visibleAnchorID) != nil {
            return visibleAnchorID
        }
        return window.messages.first?.id
    }

    private func loadEdge(_ side: EdgeSide) {
        guard state.content == .ready, recoveryTask == nil, edge(side) == .idle else { return }
        let query: ListMessagesQuery
        switch side {
        case .older:
            guard let cursor = window.olderCursor else { return }
            query = .init(before: cursor, max: Self.pageSize, threadID: threadID)
        case .newer:
            guard let cursor = window.newerCursor else { return }
            query = .init(after: cursor, max: Self.pageSize, threadID: threadID)
        }
        setEdge(side, .loading)
        let requestGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await fetchSnapshot(
                    query: query, mode: .page(side), generation: requestGeneration
                ) {
                    self.setEdge(side, .idle)
                    self.publish()
                }
            } catch is CancellationError {
                if generation == requestGeneration { setEdge(side, .idle) }
            } catch { if generation == requestGeneration { setEdge(side, .failed) } }
        }
        switch side {
        case .older: olderTask = task
        case .newer: newerTask = task
        }
    }

    private enum SnapshotMode {
        case replace(latest: Bool)
        case page(EdgeSide)
        case seekOlder
    }

    private struct MessageNotFound: Error {}

    /// The baseline, ordered replay and caller's publication execute without a suspension.
    private func fetchSnapshot(
        query: ListMessagesQuery, mode: SnapshotMode, generation requestGeneration: Int,
        requiredMessageID: String? = nil, commit: () -> Void
    ) async throws {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let token = messageStore.beginSnapshot(chatID: chatID)
        snapshotTokens.insert(token)
        defer {
            messageStore.endSnapshot(token)
            snapshotTokens.remove(token)
        }
        let page = try await source.fetchMessages(chatID: chatID, query: query)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        if let requiredMessageID,
            !page.messages.contains(where: { $0.id == requiredMessageID && accepts($0) })
        {
            throw MessageNotFound()
        }
        let events = messageStore.eventsDuringSnapshot(token)
        switch mode {
        case .replace(let latest):
            window.replace(with: page, accepting: accepts)
            windowRevision &+= 1
            viewportRevision = nil
            lastViewport = .empty
            bottomVisibleMessageDate = nil
            visibleAnchorID = nil
            pendingScroll = nil
            if latest { reconcileDeferredWithLatest() }
        case .seekOlder:
            // Seeking the oldest page must not retain the entire conversation.
            // An empty terminal page still leaves the previous accessible page usable.
            if page.messages.isEmpty {
                window.prependOlder(page, accepting: accepts)
            } else {
                window.replace(with: page, accepting: accepts)
            }
        case .page(.older): window.prependOlder(page, accepting: accepts)
        case .page(.newer): window.appendNewer(page, accepting: accepts)
        }
        preHistoryAcknowledgementKeys.removeAll()
        for event in events { reduce(event, replay: true) }
        absorbDeferredCreates()
        if let lastReadMessageID, let index = window.index(ofServerID: lastReadMessageID) {
            advanceReadWatermark(to: window.messages[index])
        }
        commit()
    }

    private func accepts(_ message: MessageResponse) -> Bool {
        guard message.chatId == chatID else { return false }
        if let threadID { return message.id == threadID || message.replyRootId == threadID }
        return message.replyRootId == nil
    }

    private func observeChanges() {
        guard observation == nil else { return }
        observation = messageStore.changes.sink { [weak self] change in self?.storeDidChange(change)
        }
    }

    private func storeDidChange(_ change: ConversationChange) {
        switch change {
        case .reset:
            invalidateRequests()
            clearWindow()
        case .pendingChanged(let changedChatID):
            guard changedChatID == chatID else { return }
            canReuseLatestWindowAfterPendingChange =
                canReuseLatestWindowAfterPendingChange || canReuseLatestWindow
            publish()
        case .realtime(let event):
            guard event.conversationChatID == chatID else { return }
            if isBeforeInitialHistory, case .message(let message) = event, accepts(message),
                lastProjection?.entries.contains(where: {
                    guard case .pending(let pending) = $0 else { return false }
                    return pending.clientGeneratedID == message.clientGeneratedId
                        && pending.senderID == message.sender.uid
                }) == true
            {
                preHistoryAcknowledgementKeys.insert(message.timelineStableKey)
            }
            let appended = reduce(event, replay: false)
            publish(
                animateFollowing: !isBeforeInitialHistory && appended && state.live.followsLatest)
        }
    }

    private var isBeforeInitialHistory: Bool {
        state.content == .idle || state.content == .loadingInitial
            || state.content == .initialLoadFailed
    }

    /// Returns whether a genuinely new row was appended. Replay repairs data only.
    @discardableResult
    private func reduce(_ event: RealtimeServerEvent, replay: Bool) -> Bool {
        guard event.conversationChatID == chatID else { return false }
        switch event {
        case .message(let message):
            guard accepts(message), replay || !deletedIDs.contains(message.id) else { return false }
            if window.index(matching: message) != nil || deferredKey(matching: message) != nil {
                // Publication replaces an acknowledged M4A with canonical Opus
                // through a create event, not messageUpdated. Merge only that
                // one-way attachment transition: an unversioned duplicate create
                // must not undo newer edits, reactions, deletion, or canonical audio.
                if message.messageType == .audio, !message.isDeleted,
                    message.attachments.count == 1, message.attachments[0].kind == "audio/ogg"
                {
                    mutateKnown(message) { existing in
                        guard existing.messageType == .audio, !existing.isDeleted,
                            !deletedIDs.contains(existing.id), existing.attachments.count == 1,
                            existing.attachments[0].kind.hasPrefix("audio/"),
                            existing.attachments[0].kind != "audio/ogg"
                        else { return existing }
                        return existing.replacingAttachments(message.attachments)
                    }
                }
                return false
            }
            let content = deletedIDs.contains(message.id) ? message.redactedForDeletion() : message
            let message = content.redactingReplyPreview(messageIDs: deletedIDs)
            let outcome: TimelineWindow.LiveInsertOutcome
            if isBeforeInitialHistory && !replay {
                outcome = .deferred
            } else {
                outcome = window.insertLive(message)
            }
            if outcome == .deferred { deferredCreates[message.timelineStableKey] = message }
            return outcome == .appended
        case .messageUpdated(let message):
            guard accepts(message) else { return false }
            mutateKnown(message) { existing in
                let updated =
                    (existing.isDeleted || deletedIDs.contains(message.id))
                    ? message.redactedForDeletion() : message
                return updated.redactingReplyPreview(messageIDs: deletedIDs)
            }
        case .messageDeleted(let message):
            deletedIDs.insert(message.id)
            if accepts(message) { mutateKnown(message) { _ in message.redactedForDeletion() } }
            redactDeletedPreviews([message.id])
        case .messagesBulkDeleted(let payload):
            let ids = Set(payload.messageIds)
            deletedIDs.formUnion(ids)
            mutateRecords { message in
                let redacted = ids.contains(message.id) ? message.redactedForDeletion() : message
                return redacted.redactingReplyPreview(messageIDs: ids)
            }
        case .reactionUpdated(let payload):
            mutateServerID(payload.messageId) { $0.replacingReactions(payload.reactions) }
        case .threadUpdate(let payload):
            mutateServerID(payload.threadRootId) {
                $0.replacingThreadReplyCount(payload.replyCount)
            }
        case .pong, .chatArchiveStateChanged, .presenceUpdate, .threadMembershipChanged,
            .pinAdded, .threadPinAdded, .pinRemoved, .threadPinRemoved, .stickerPackOrderUpdated,
            .friendRequestReceived, .friendRequestResolved, .friendshipRemoved, .unknown:
            break
        }
        return false
    }

    private func deferredKey(matching message: MessageResponse) -> ConversationMessageStableKey? {
        deferredCreates.first(where: { $0.value.id == message.id })?.key
            ?? (message.clientGeneratedId.isEmpty
                || deferredCreates[message.timelineStableKey] == nil
                ? nil : message.timelineStableKey)
    }

    private func mutateKnown(
        _ message: MessageResponse, mutation: (MessageResponse) -> MessageResponse
    ) {
        if let index = window.index(matching: message) {
            window.upsert(mutation(window.messages[index]))
        }
        if let key = deferredKey(matching: message), let existing = deferredCreates[key] {
            let updated = mutation(existing)
            deferredCreates.removeValue(forKey: key)
            deferredCreates[updated.timelineStableKey] = updated
        }
    }

    private func mutateServerID(_ id: String, mutation: (MessageResponse) -> MessageResponse) {
        if let index = window.index(ofServerID: id) {
            window.upsert(mutation(window.messages[index]))
        }
        if let entry = deferredCreates.first(where: { $0.value.id == id }) {
            deferredCreates[entry.key] = mutation(entry.value)
        }
    }

    private func mutateRecords(_ mutation: (MessageResponse) -> MessageResponse) {
        for message in window.messages {
            let updated = mutation(message)
            if updated != message { window.upsert(updated) }
        }
        for (key, message) in deferredCreates { deferredCreates[key] = mutation(message) }
    }

    private func redactDeletedPreviews(_ ids: Set<String>) {
        mutateRecords { $0.redactingReplyPreview(messageIDs: ids) }
    }

    private func reconcileDeferredWithLatest() {
        guard let newest = window.messages.last else {
            deferredCreates.removeAll()
            return
        }
        deferredCreates = deferredCreates.filter {
            window.index(matching: $0.value) == nil && $0.value.createdAt >= newest.createdAt
        }
    }

    private func absorbDeferredCreates() {
        guard window.isAtLiveEdge else { return }
        for message in TimelineWindow.chronological(Array(deferredCreates.values)) {
            _ = window.insertLive(message)
        }
        deferredCreates.removeAll()
    }

    private func clearWindow() {
        let unreadCount = state.live.unreadCount
        window = TimelineWindow()
        windowRevision &+= 1
        unreadBeforeMessageID = nil
        hasSentEntryRead = false
        deferredCreates.removeAll()
        preHistoryAcknowledgementKeys.removeAll()
        canReuseLatestWindowAfterPendingChange = false
        deletedIDs.removeAll()
        state = ConversationTimelineState()
        state.live.unreadCount = unreadCount
        pendingScroll = nil
        lastViewport = .empty
        bottomVisibleMessageDate = nil
        visibleAnchorID = nil
        viewportRevision = nil
        publish(reset: true)
    }

    private func invalidateRequests() {
        canReuseLatestWindowAfterPendingChange = false
        cancelReadCandidate()
        readSendTask?.cancel()
        viewportRevision = nil
        generation &+= 1
        initialTask?.cancel()
        initialTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        olderTask?.cancel()
        newerTask?.cancel()
        olderTask = nil
        newerTask = nil
        state.older = .idle
        state.newer = .idle
        for token in snapshotTokens { messageStore.endSnapshot(token) }
        snapshotTokens.removeAll()
    }

    private func edge(_ side: EdgeSide) -> ConversationTimelineState.Edge {
        side == .older ? state.older : state.newer
    }
    private func setEdge(_ side: EdgeSide, _ value: ConversationTimelineState.Edge) {
        if side == .older { state.older = value } else { state.newer = value }
    }
    private var liveEdgeQuery: ListMessagesQuery { .init(max: Self.pageSize, threadID: threadID) }
    private func aroundQuery(for position: TimelineInitialPosition) -> ListMessagesQuery {
        if case .message(let id) = position {
            return .init(around: id, max: Self.pageSize, threadID: threadID)
        }
        return liveEdgeQuery
    }
    private func rowID(forServerID id: String) -> TimelineRowID? {
        guard !deletedIDs.contains(id), let index = window.index(ofServerID: id),
            !window.messages[index].isDeleted
        else { return nil }
        return .message(window.messages[index].timelineStableKey)
    }

    private func publish(
        animateFollowing: Bool = false, position: TimelineScrollIntent? = nil, reset: Bool = false
    ) {
        if state.live.pendingLiveCount != deferredCreates.count {
            state.live.pendingLiveCount = deferredCreates.count
        }
        var remoteMessages = window.messages
        if isBeforeInitialHistory {
            for (key, message) in deferredCreates where preHistoryAcknowledgementKeys.contains(key)
            {
                remoteMessages.append(message)
            }
        }
        let projection = messageStore.projection(
            for: chatID, threadID: threadID, remoteMessages: remoteMessages,
            includePendingOutgoing: true)
        let changed = projection != lastProjection || reset
        if changed {
            // Keep tombstones in the window for pagination and acknowledgement
            // reconciliation, but exclude them before grouping and separators.
            let visibleEntries = projection.entries.filter { entry in
                guard let message = entry.remoteMessage else { return true }
                return !message.isDeleted && !deletedIDs.contains(message.id)
            }
            let newRows = builder.build(
                visibleEntries, unreadBeforeMessageID: unreadBeforeMessageID)
            if newRows != rows { rows = newRows }
            lastProjection = projection
            snapshotRevision &+= 1
            viewportRevision = nil
            cancelReadCandidate()
        }
        if let position { issueScroll(position) }
        guard changed || position != nil else { return }
        updates.send(
            .init(
                revision: snapshotRevision, windowRevision: windowRevision, rows: rows,
                animateFollowing: animateFollowing, pendingScroll: pendingScroll))
    }

    private func requestScroll(_ intent: TimelineScrollIntent) {
        issueScroll(intent)
        updates.send(
            .init(
                revision: snapshotRevision, windowRevision: windowRevision, rows: rows,
                animateFollowing: false, pendingScroll: pendingScroll))
    }
    private func issueScroll(_ intent: TimelineScrollIntent) {
        cancelReadCandidate()
        viewportRevision = nil
        scrollRequestID &+= 1
        pendingScroll = .init(id: scrollRequestID, intent: intent)
    }
}
