import ChahuaAPI
import Combine
import Foundation

enum TimelineInitialPosition: Equatable {
    case liveEdge
    case message(MessageID)
    case unread(after: MessageID?)
}

enum TimelineMessageJumpOutcome: Equatable {
    case reached
    case missing
    case failed
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
    /// The thread root is a message; parsed once for per-message acceptance checks.
    private let threadRootID: MessageID?
    @Published private(set) var state = ConversationTimelineState()
    @Published private(set) var rows: [TimelineRow] = []
    @Published private(set) var bottomVisibleMessageDate: Date?
    @Published private(set) var unreadMentionJumpCount = 0
    @Published private(set) var unreadReactionJumpCount = 0
    @Published private(set) var activityJumpInProgress = false
    var isAtLiveEdge: Bool { window.isAtLiveEdge }
    var jumpUnreadCount: Int64 { state.live.unreadCount }
    /// Selection survives pagination, but must discard messages deleted by realtime events.
    var knownDeletedMessageIDs: Set<MessageID> { deletedIDs }
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
    private let markRead: (@MainActor (MessageID) async throws -> Void)?
    private let fetchReadReceipt: (@MainActor (String?) async throws -> MessageID?)?
    private var readReceiptID: MessageID?
    private var rootReadReceiptID: MessageID?
    private var receiptRevision = 0
    private var receiptTask: Task<Void, Never>?
    // Bit 1 is this conversation; bit 2 is the parent receipt shown on a thread root.
    private var receiptFresh = 0
    private var receiptDirty = 0
    private var window = TimelineWindow()
    private var observation: AnyCancellable?
    private var deferredCreates: [ConversationMessageStableKey: MessageResponse] = [:]
    private var preHistoryAcknowledgementKeys: Set<ConversationMessageStableKey> = []
    private var deletedIDs: Set<MessageID> = []
    private var snapshotTokens: Set<UUID> = []
    private var generation = 0
    private var snapshotRevision = 0
    private var windowRevision = 0
    private var scrollRequestID = 0
    private var pendingScroll: TimelineScrollRequest?
    private var lastEntries: [ConversationTimelineEntry]?
    private var lastViewport = TimelineViewport.empty
    @Published private(set) var viewportRevision: Int?
    private var visibleAnchorID: MessageID?
    private var lastInitialPosition: TimelineInitialPosition = .liveEdge
    private var initialTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var olderTask: Task<Void, Never>?
    private var newerTask: Task<Void, Never>?
    private var accountResetObservation: AnyCancellable?
    // A committed pending publication invalidates the host's viewport revision before reveal runs.
    private var canReuseLatestWindowAfterPendingChange = false
    // The entry boundary is frozen until the next open, independent of read receipts.
    private var unreadBeforeMessageID: MessageID?
    private var lastReadMessageID: MessageID?
    private var hasAuthoritativeReadState = false
    /// The newest authoritative or successfully acknowledged read cursor, loaded or not.
    private var readWatermark: MessageID?
    private var readWatermarkRevision = 0
    private var readTrackingActive = false
    private var hasSentEntryRead = false
    private var readCandidateID: MessageID?
    private var readCandidateMature = false
    private var readDwellTask: Task<Void, Never>?
    private var readSendTask: Task<Void, Never>?
    let isGroupChat: Bool
    private let fetchUnreadMentions:
        (@MainActor (String?) async throws -> UnreadMentionIDsResponse)?
    private let fetchUnreadReactions:
        (@MainActor (String?) async throws -> UnreadReactionIDsResponse)?
    private let acknowledgeReactions:
        (@MainActor (String?, String?) async throws -> UnreadReactionsAckResponse)?
    private var mentionTargets: Set<MessageID> = []
    private var dismissedMentionTargets: Set<MessageID> = []
    private var reactionTargets: Set<MessageID> = []
    // Activity revisions are independent of history pagination and repositioning.
    private var activityRevision = 0
    private var mentionTask: Task<Void, Never>?
    private var reactionTask: Task<Void, Never>?
    private var leaveReactionTask: Task<Void, Never>?
    private var leaveReactionRevision: Int?
    private var mentionsDirty = true
    private var reactionsDirty = true
    private var mentionsChanged = false
    private var reactionsChanged = false
    private var knownUnreadMentions: Int64?
    private var knownUnreadReactions: Int64?
    private var accountWasReset = false
    private var membershipRefreshRequired = false
    var hasPendingMembershipVisibilityRefresh: Bool { membershipRefreshRequired }
    private var membershipRefreshLowerBound: MessageID?
    private var membershipRefreshUpperBound: MessageID?
    private var membershipRefreshAtLiveEdge = false

    init(
        chatID: String, currentUserID: Int32, isGroupChat: Bool, source: any TimelineMessageSource,
        messageStore: ConversationMessageStore, threadID: String? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        capturedReplyRedactedIDs: Set<MessageID> = [],
        markRead: (@MainActor (MessageID) async throws -> Void)? = nil,
        fetchReadReceipt: (@MainActor (String?) async throws -> MessageID?)? = nil,
        fetchUnreadMentions: (@MainActor (String?) async throws -> UnreadMentionIDsResponse)? = nil,
        fetchUnreadReactions: (@MainActor (String?) async throws -> UnreadReactionIDsResponse)? =
            nil,
        acknowledgeReactions:
            (@MainActor (String?, String?) async throws -> UnreadReactionsAckResponse)? = nil
    ) {
        self.chatID = chatID
        self.threadID = threadID
        threadRootID = threadID.flatMap(MessageID.init)
        self.currentUserID = currentUserID
        self.source = source
        self.messageStore = messageStore
        self.markRead = markRead
        self.fetchReadReceipt = fetchReadReceipt
        self.isGroupChat = isGroupChat
        self.fetchUnreadMentions = fetchUnreadMentions
        self.fetchUnreadReactions = fetchUnreadReactions
        self.acknowledgeReactions = acknowledgeReactions
        builder = TimelineRowsBuilder(
            currentUserID: currentUserID, calendar: calendar,
            capturedReplyRedactedIDs: capturedReplyRedactedIDs)
        // A final leave acknowledgement can outlive timeline observation. Keep the account
        // fence subscribed until the model dies so it cannot write for a replacement login.
        accountResetObservation = messageStore.changes.sink { [weak self] change in
            guard case .reset = change, let self else { return }
            accountWasReset = true
            setReadTrackingActive(false)
            resetUnreadActivity()
        }
        observeChanges()
        publish()
    }

    func setRealtimeStatus(_ status: RealtimeConnectionStatus) {
        guard state.realtimeStatus != status else { return }
        state.realtimeStatus = status
        if status == .connected {
            refreshReadReceipt(changed: false, mask: receiptMask & ~receiptFresh)
            refreshUnreadActivity(changed: false)
        } else {
            // A transport gap invalidates freshness, not already authorized content.
            receiptFresh = 0
            mentionsDirty = true
            reactionsDirty = true
            mentionsChanged = true
            reactionsChanged = true
            cancelReadReceipt(clear: false)
        }
    }

    private var receiptMask: Int { threadID == nil ? 1 : 3 }

    func readReceiptChanged(_ payload: ReadReceiptChangedPayload) {
        guard payload.chatId == chatID else { return }
        if payload.privacyChanged == true || payload.readerUid == nil {
            refreshReadReceipt(clear: payload.privacyChanged == true)
        } else if payload.readerUid != currentUserID {
            if payload.threadRootId == threadRootID {
                refreshReadReceipt(mask: 1)
            } else if payload.threadRootId == nil, threadID != nil {
                refreshReadReceipt(mask: 2)
            }
        }
    }

    /// Lifecycle callers share successful data and in-flight work; server changes queue
    /// one follow-up for only the affected scope. Privacy revocation fences old responses.
    func refreshReadReceipt(clear: Bool = false, changed: Bool = true, mask: Int = 3) {
        let requested = mask & receiptMask
        if clear { cancelReadReceipt(clear: true) }
        guard !isGroupChat, fetchReadReceipt != nil, requested != 0 else { return }
        if changed {
            receiptFresh &= ~requested
            receiptDirty |= requested
        } else if receiptTask == nil {
            receiptDirty |= requested & ~receiptFresh
        }
        startReadReceiptRefresh()
    }

    private func startReadReceiptRefresh() {
        guard readTrackingActive, receiptTask == nil, receiptDirty != 0,
            let fetchReadReceipt
        else { return }
        let revision = receiptRevision
        receiptTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if receiptRevision == revision { receiptTask = nil }
            }
            while readTrackingActive, receiptRevision == revision, !Task.isCancelled,
                receiptDirty != 0
            {
                let requested = receiptDirty
                receiptDirty = 0
                do {
                    async let scope = requested & 1 != 0 ? fetchReadReceipt(threadID) : nil
                    async let root = requested & 2 != 0 ? fetchReadReceipt(nil) : nil
                    let (scopeID, rootID) = try await (scope, root)
                    guard !Task.isCancelled, receiptRevision == revision, readTrackingActive else {
                        return
                    }
                    if requested & 1 != 0 { readReceiptID = scopeID }
                    if requested & 2 != 0 { rootReadReceiptID = rootID }
                    receiptFresh |= requested & ~receiptDirty
                    lastEntries = nil
                    publish()
                } catch {
                    // Preserve authorized receipts, but let foreground retry failed scopes.
                    guard receiptRevision == revision, !Task.isCancelled else { return }
                    receiptFresh &= ~requested
                    if receiptDirty == 0 { return }
                }
            }
        }
    }

    private func cancelReadReceipt(clear: Bool) {
        receiptRevision &+= 1
        receiptTask?.cancel()
        receiptTask = nil
        receiptDirty = 0
        if clear { receiptFresh = 0 }
        if clear, readReceiptID != nil || rootReadReceiptID != nil {
            readReceiptID = nil
            rootReadReceiptID = nil
            lastEntries = nil
            publish()
        }
    }

    /// Unlike fixture-oriented loadInitial, every appearance requests a fresh entry window.
    func open(position: TimelineInitialPosition = .liveEdge) async {
        invalidateRequests()
        observeChanges()
        clearWindow()
        await loadInitial(position: position)
    }

    func close(acknowledgingActivity: Bool = false) {
        let shouldAcknowledge = acknowledgingActivity && readTrackingActive
        setReadTrackingActive(false)
        cancelReadReceipt(clear: true)
        resetUnreadActivity()
        invalidateRequests()
        observation = nil
        if shouldAcknowledge, let acknowledgeReactions {
            let revision = activityRevision
            let scope = threadID
            leaveReactionRevision = revision
            leaveReactionTask = Task { [self] in
                defer {
                    if leaveReactionRevision == revision {
                        leaveReactionTask = nil
                        leaveReactionRevision = nil
                        startReactionRefresh()
                    }
                }
                guard !Task.isCancelled, activityRevision == revision else { return }
                _ = try? await acknowledgeReactions(scope, nil)
            }
        }
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

    private func loadUnreadEntry(after lastReadID: MessageID?, generation requestGeneration: Int)
        async throws
    {
        if !hasAuthoritativeReadState, let lastReadID { advanceReadWatermark(to: lastReadID) }
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

        if let lastReadID, window.index(ofServerID: lastReadID) != nil {
            // Cursor presence affects seeking, not whether its read progress is known.
            var cursors: Set<MessageID> = []
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
            var cursors: Set<MessageID> = []
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
    func updateReadState(unreadCount: Int64, lastReadMessageID: MessageID?) {
        hasAuthoritativeReadState = true
        self.lastReadMessageID = lastReadMessageID
        let count = max(0, unreadCount)
        if state.live.unreadCount != count { state.live.unreadCount = count }
        if let lastReadMessageID { advanceReadWatermark(to: lastReadMessageID) }
        updateReadCandidate()
    }

    /// Explicit unread state replaces suppression without moving the frozen entry separator.
    func resetReadWatermark(to id: MessageID?) {
        hasAuthoritativeReadState = true
        readWatermarkRevision &+= 1
        readWatermark = id
        lastReadMessageID = id
        cancelReadCandidate()
        // Retain the task until completion to serialize callbacks that ignore cancellation.
        readSendTask?.cancel()
        updateReadCandidate()
    }

    func setReadTrackingActive(_ active: Bool) {
        if !active {
            cancelUnreadActivity()
            if activityJumpInProgress { invalidateRequests() }
        }
        guard !active || !accountWasReset else { return }
        guard readTrackingActive != active else { return }
        if active {
            activityRevision &+= 1
            leaveReactionTask?.cancel()
        }
        readTrackingActive = active
        if active {
            refreshReadReceipt(changed: false, mask: receiptMask & ~receiptFresh)
            refreshUnreadActivity(changed: false)
        } else {
            cancelReadReceipt(clear: false)
        }
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

    /// Reuse authoritative zeroes only until a scoped event or transport gap invalidates them.
    func updateUnreadActivityState(unreadMentions: Int64, unreadReactions: Int64) {
        let mentionChanged = knownUnreadMentions.map { $0 != unreadMentions } ?? false
        let reactionChanged = knownUnreadReactions.map { $0 != unreadReactions } ?? false
        knownUnreadMentions = max(0, unreadMentions)
        knownUnreadReactions = max(0, unreadReactions)
        if (mentionChanged && unreadMentions > 0) || (reactionChanged && unreadReactions > 0) {
            refreshUnreadActivity(
                mentions: mentionChanged && unreadMentions > 0,
                reactions: reactionChanged && unreadReactions > 0)
        } else {
            refreshUnreadActivity(changed: false)
        }
    }

    /// Lifecycle calls share loaded results; scoped changes coalesce into one more request.
    func refreshUnreadActivity(
        mentions: Bool = true, reactions: Bool = true, changed: Bool = true
    ) {
        if mentions, isGroupChat, fetchUnreadMentions != nil {
            if changed {
                mentionsDirty = true
                mentionsChanged = true
            }
            if mentionsDirty, !mentionsChanged, knownUnreadMentions == 0 {
                mentionsDirty = false
            }
            startMentionRefresh()
        }
        if reactions, fetchUnreadReactions != nil {
            if changed {
                reactionsDirty = true
                reactionsChanged = true
            }
            if reactionsDirty, !reactionsChanged, knownUnreadReactions == 0 {
                reactionsDirty = false
            }
            startReactionRefresh()
        }
    }

    private func startMentionRefresh() {
        guard mentionTask == nil, mentionsDirty, readTrackingActive,
            let fetchUnreadMentions
        else { return }
        let revision = activityRevision
        mentionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                mentionTask = nil
                if revision != activityRevision { startMentionRefresh() }
            }
            while readTrackingActive, revision == activityRevision, !Task.isCancelled,
                mentionsDirty
            {
                mentionsDirty = false
                do {
                    let response = try await fetchUnreadMentions(threadID)
                    guard readTrackingActive, revision == activityRevision, !Task.isCancelled else {
                        return
                    }
                    mentionTargets.formUnion(
                        response.messageIds.lazy.filter {
                            !self.dismissedMentionTargets.contains($0)
                                && !self.isActivityTargetDeleted($0)
                        })
                    publishActivityCounts()
                    if !mentionsDirty { mentionsChanged = false }
                } catch {
                    if !mentionsDirty {
                        mentionsDirty = true
                        return
                    }
                }
            }
        }
    }

    private func startReactionRefresh() {
        guard reactionTask == nil, leaveReactionTask == nil, reactionsDirty, readTrackingActive,
            let fetchUnreadReactions
        else { return }
        let revision = activityRevision
        reactionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                reactionTask = nil
                if revision != activityRevision { startReactionRefresh() }
            }
            while readTrackingActive, revision == activityRevision, !Task.isCancelled,
                reactionsDirty
            {
                reactionsDirty = false
                do {
                    let response = try await fetchUnreadReactions(threadID)
                    guard readTrackingActive, revision == activityRevision, !Task.isCancelled else {
                        return
                    }
                    reactionTargets.formUnion(
                        response.messageIds.lazy.filter { !self.isActivityTargetDeleted($0) })
                    publishActivityCounts()
                    // Never acknowledge a failed GET, or a response from an inactive session.
                    if let acknowledgeReactions {
                        let ack = try await acknowledgeReactions(threadID, response.readThrough)
                        guard readTrackingActive, revision == activityRevision, !Task.isCancelled
                        else {
                            return
                        }
                        if ack.unreadReactions > 0 { reactionsDirty = true }
                    }
                    if !reactionsDirty { reactionsChanged = false }
                } catch {
                    if !reactionsDirty {
                        reactionsDirty = true
                        return
                    }
                }
            }
        }
    }

    private func cancelUnreadActivity() {
        activityRevision &+= 1
        if mentionTask != nil { mentionsDirty = true }
        if reactionTask != nil { reactionsDirty = true }
        // Keep cancelled tasks until their callbacks return: clients may ignore cancellation.
        mentionTask?.cancel()
        reactionTask?.cancel()
        leaveReactionTask?.cancel()
    }

    private func resetUnreadActivity() {
        cancelUnreadActivity()
        mentionsDirty = true
        reactionsDirty = true
        mentionsChanged = false
        reactionsChanged = false
        mentionTargets.removeAll()
        dismissedMentionTargets.removeAll()
        reactionTargets.removeAll()
        publishActivityCounts()
    }

    private func isActivityTargetDeleted(_ id: MessageID) -> Bool {
        deletedIDs.contains(id)
            || window.messages.contains(where: { $0.id == id && $0.isDeleted })
            || deferredCreates.values.contains(where: { $0.id == id && $0.isDeleted })
    }

    private func publishActivityCounts() {
        unreadMentionJumpCount = mentionTargets.count
        unreadReactionJumpCount = reactionTargets.count
    }

    private func removeActivityTargets(_ ids: Set<MessageID>) {
        dismissedMentionTargets.formUnion(ids)
        mentionTargets.subtract(ids)
        reactionTargets.subtract(ids)
        publishActivityCounts()
    }

    func jumpToNextMention() async { await jumpToNextActivity(mention: true) }

    func jumpToNextReaction() async { await jumpToNextActivity(mention: false) }

    private func jumpToNextActivity(mention: Bool) async {
        guard readTrackingActive, !activityJumpInProgress else { return }
        activityJumpInProgress = true
        defer { activityJumpInProgress = false }
        let revision = activityRevision
        while readTrackingActive, revision == activityRevision,
            let id = (mention ? mentionTargets : reactionTargets).min()
        {
            let outcome = await jumpToMessage(id)
            guard readTrackingActive, revision == activityRevision else { return }
            switch outcome {
            case .failed:
                return
            case .missing:
                removeActivityTargets([id])
            case .reached:
                if mention {
                    dismissedMentionTargets.insert(id)
                    mentionTargets.remove(id)
                } else {
                    reactionTargets.remove(id)
                }
                publishActivityCounts()
                return
            }
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
            let candidateID = lastViewport.visibleMessageIDs.last,
            candidateID != threadRootID
        else { return nil }
        for index in (first...last).reversed() {
            guard case .message(let row) = rows[index], let message = row.entry.remoteMessage,
                message.id == candidateID
            else { continue }
            return isLaterThanWatermark(message) ? message : nil
        }
        return nil
    }

    private func isLaterThanWatermark(_ message: MessageResponse) -> Bool {
        guard let readWatermark else { return true }
        return message.id > readWatermark
    }

    private func advanceReadWatermark(to id: MessageID) {
        if readWatermark.map({ id > $0 }) ?? true { readWatermark = id }
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
        let watermarkRevision = readWatermarkRevision
        readSendTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard self?.generation == requestGeneration,
                    self?.readCandidateID == candidate.id,
                    self?.readWatermarkRevision == watermarkRevision,
                    self?.visibleReadCandidate?.id == candidate.id
                else { throw CancellationError() }
                self?.hasSentEntryRead = true
                try await markRead(candidate.id)
                if self?.generation == requestGeneration,
                    self?.readWatermarkRevision == watermarkRevision
                {
                    self?.advanceReadWatermark(to: candidate.id)
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
        if membershipRefreshRequired {
            await reconcileMembershipVisibility()
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

    /// Uses the existing recovery task, but merges the loaded interval rather than
    /// replacing it with one page. Visibility changes must not discard paged history.
    private func reconcileMembershipVisibility() async {
        let requestGeneration = generation
        let lower = membershipRefreshLowerBound ?? window.messages.first?.id
        let upper =
            membershipRefreshAtLiveEdge
            ? nil
            : (membershipRefreshUpperBound ?? window.messages.last?.id)
        membershipRefreshRequired = false
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == requestGeneration { recoveryTask = nil } }
            do {
                guard let lower else {
                    try await fetchSnapshot(
                        query: liveEdgeQuery, mode: .replace(latest: true),
                        generation: requestGeneration
                    ) {
                        self.state.content = .ready
                        self.publish()
                    }
                    return
                }
                var query = aroundQuery(for: .message(lower))
                var cursors = Set<MessageID>()
                while true {
                    let next = try await fetchSnapshot(
                        query: query, mode: .membershipRange(lower: lower, upper: upper),
                        generation: requestGeneration
                    ) {
                        self.publish()
                    }
                    guard let cursor = next, upper.map({ cursor < $0 }) ?? true else { break }
                    guard cursors.insert(cursor).inserted else { throw APIError.unexpectedResponse }
                    query = .init(after: cursor, max: Self.pageSize, threadID: threadID)
                }
                if !membershipRefreshRequired {
                    membershipRefreshLowerBound = nil
                    membershipRefreshUpperBound = nil
                    membershipRefreshAtLiveEdge = false
                }
                state.reconciliationFailed = false
            } catch {
                guard generation == requestGeneration else { return }
                membershipRefreshRequired = true
                if !(error is CancellationError) { state.reconciliationFailed = true }
            }
        }
        recoveryTask = task
        await awaitRecovery(task, generation: requestGeneration)
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
            previousAnchorID != visibleAnchorID
        {
            nextLive.scrollsTowardNewer = visibleAnchorID > previousAnchorID
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
        guard let lastReadMessageID, let visibleID = lastViewport.visibleMessageIDs.last else {
            return false
        }
        return visibleID >= lastReadMessageID
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

    @discardableResult
    func jumpToMessage(_ id: MessageID, atReadBoundary: Bool = false) async
        -> TimelineMessageJumpOutcome
    {
        switch state.content {
        case .ready, .repositioning: break
        default: return .failed
        }
        invalidateRequests()
        state.repositionFailure = nil
        state.content = .ready
        if isActivityTargetDeleted(id) {
            state.repositionFailure = .message(id)
            return .missing
        }
        if let rowID = rowID(forServerID: id) {
            state.live.followsLatest = false
            requestScroll(
                atReadBoundary
                    ? .readBoundary(rowID, animated: true)
                    : .reveal(rowID, animated: true, highlight: true))
            return .reached
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
            return rowID(forServerID: id) == nil ? .missing : .reached
        } catch is CancellationError {
            if generation == requestGeneration { state.content = .ready }
            return .failed
        } catch {
            guard generation == requestGeneration else { return .failed }
            state.content = .ready
            if atReadBoundary {
                await jumpToLiveEdge()
            } else {
                state.repositionFailure = .message(id)
            }
            if error is MessageNotFound { return .missing }
            if let apiError = error as? APIError {
                switch apiError {
                case .http(status: 404, body: _), .invalidResponse(statusCode: 404):
                    return .missing
                default:
                    break
                }
            }
            return .failed
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

    private var visibleRemoteAnchor: MessageID? {
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
        case membershipRange(lower: MessageID, upper: MessageID?)
    }

    private struct MessageNotFound: Error {}

    /// The baseline, ordered replay and caller's publication execute without a suspension.
    @discardableResult
    private func fetchSnapshot(
        query: ListMessagesQuery, mode: SnapshotMode, generation requestGeneration: Int,
        requiredMessageID: MessageID? = nil, commit: () -> Void
    ) async throws -> MessageID? {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        var token = messageStore.beginSnapshot(chatID: chatID)
        snapshotTokens.insert(token)
        defer {
            messageStore.endSnapshot(token)
            snapshotTokens.remove(token)
        }
        var page: ListMessagesResponse
        while true {
            page = try await source.fetchMessages(chatID: chatID, query: query)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            guard isGroupChat, threadID == nil,
                !messageStore.membershipSnapshotIsCurrent(token)
            else { break }
            // Metadata can change while this actor is suspended returning from
            // the source, even after its own response fence has passed.
            messageStore.endSnapshot(token)
            snapshotTokens.remove(token)
            token = messageStore.beginSnapshot(chatID: chatID)
            snapshotTokens.insert(token)
        }
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
        case .membershipRange(let lower, let upper):
            window.mergePreservingCursors(page) { message in
                message.id >= lower && (upper.map { message.id <= $0 } ?? true)
                    && self.accepts(message)
            }
        }
        preHistoryAcknowledgementKeys.removeAll()
        for event in events { reduce(event, replay: true) }
        absorbDeferredCreates()
        commit()
        return page.newerCursor
    }

    private func accepts(_ message: MessageResponse) -> Bool {
        guard message.chatId == chatID else { return false }
        if threadID != nil {
            return message.id == threadRootID || message.replyRootId == threadID
        }
        return message.replyRootId == nil
            && !(isGroupChat && message.systemKind?.isMembership == true
                && messageStore.hidesMembershipMessages(chatID: chatID))
    }

    private func observeChanges() {
        guard observation == nil else { return }
        observation = messageStore.changes.sink { [weak self] change in self?.storeDidChange(change)
        }
    }

    private func storeDidChange(_ change: ConversationChange) {
        switch change {
        case .reset:
            cancelReadReceipt(clear: true)
            invalidateRequests()
            clearWindow()
        case .membershipVisibilityChanged(let changedChatID):
            guard isGroupChat, threadID == nil,
                changedChatID == nil || changedChatID == chatID
            else { return }
            let lower = window.messages.first?.id
            let upper = window.messages.last?.id
            membershipRefreshAtLiveEdge = membershipRefreshAtLiveEdge || window.isAtLiveEdge
            if let lower {
                membershipRefreshLowerBound = min(membershipRefreshLowerBound ?? lower, lower)
            }
            if let upper {
                membershipRefreshUpperBound = max(membershipRefreshUpperBound ?? upper, upper)
            }
            membershipRefreshRequired = true
            let hidden = Set(
                window.messages.lazy.filter { !self.accepts($0) }.map(\.id))
            window.removeAll { !self.accepts($0) }
            deferredCreates = deferredCreates.filter { self.accepts($0.value) }
            removeActivityTargets(hidden)
            resetUnreadActivity()
            refreshUnreadActivity()
            cancelReadCandidate()
            publish()
        case .pendingChanged(let changedChatID):
            guard changedChatID == chatID else { return }
            canReuseLatestWindowAfterPendingChange =
                canReuseLatestWindowAfterPendingChange || canReuseLatestWindow
            publish()
        case .realtime(let event):
            guard event.conversationChatID == chatID else { return }
            if isBeforeInitialHistory, case .message(let message) = event, accepts(message),
                lastEntries?.contains(where: {
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
            removeActivityTargets([message.id])
            if accepts(message) { mutateKnown(message) { _ in message.redactedForDeletion() } }
            redactDeletedPreviews([message.id])
        case .messagesBulkDeleted(let payload):
            let ids = Set(payload.messageIds)
            deletedIDs.formUnion(ids)
            removeActivityTargets(ids)
            mutateRecords { message in
                let redacted = ids.contains(message.id) ? message.redactedForDeletion() : message
                return redacted.redactingReplyPreview(messageIDs: ids)
            }
        case .reactionUpdated(let payload):
            mutateServerID(payload.messageId) { $0.replacingReactions(payload.reactions) }
        case .threadUpdate(let payload):
            if let rootID = MessageID(payload.threadRootId) {
                mutateServerID(rootID) { $0.replacingThreadReplyCount(payload.replyCount) }
            }
        case .pong, .chatArchiveStateChanged, .presenceUpdate, .presenceSnapshot,
            .threadMembershipChanged, .readReceiptChanged, .notification,
            .notificationSettingsChanged, .chatNotificationSettingChanged,
            .notificationExceptionsCleared, .groupSpeakingModeChanged, .memberSpeakingModeChanged,
            .membershipMessagePolicyChanged, .chatMembershipChanged,
            .conversationUnread, .conversationUnreadError, .conversationStates,
            .conversationStatesError,
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

    private func mutateServerID(_ id: MessageID, mutation: (MessageResponse) -> MessageResponse) {
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

    private func redactDeletedPreviews(_ ids: Set<MessageID>) {
        mutateRecords { $0.redactingReplyPreview(messageIDs: ids) }
    }

    private func reconcileDeferredWithLatest() {
        guard let newest = window.messages.last else {
            deferredCreates.removeAll()
            return
        }
        deferredCreates = deferredCreates.filter {
            window.index(matching: $0.value) == nil && $0.value.id > newest.id
        }
    }

    private func absorbDeferredCreates() {
        guard window.isAtLiveEdge else { return }
        // Each insertion lands at its server position; arrival order does not matter.
        for message in deferredCreates.values { _ = window.insertLive(message) }
        deferredCreates.removeAll()
    }

    private func clearWindow() {
        let unreadCount = state.live.unreadCount
        let realtimeStatus = state.realtimeStatus
        window = TimelineWindow()
        windowRevision &+= 1
        unreadBeforeMessageID = nil
        hasSentEntryRead = false
        deferredCreates.removeAll()
        preHistoryAcknowledgementKeys.removeAll()
        canReuseLatestWindowAfterPendingChange = false
        deletedIDs.removeAll()
        membershipRefreshRequired = false
        membershipRefreshLowerBound = nil
        membershipRefreshUpperBound = nil
        membershipRefreshAtLiveEdge = false
        state = ConversationTimelineState(realtimeStatus: realtimeStatus)
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
    private func rowID(forServerID id: MessageID) -> TimelineRowID? {
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
        let entries = timelineEntries()
        let changed = entries != lastEntries || reset
        if changed {
            // Keep tombstones in the window for pagination and acknowledgement
            // reconciliation, but exclude them before grouping and separators.
            let visibleEntries = entries.filter { entry in
                guard let message = entry.remoteMessage else { return true }
                return !message.isDeleted && !deletedIDs.contains(message.id)
            }
            let newRows = builder.build(
                visibleEntries, unreadBeforeMessageID: unreadBeforeMessageID,
                readReceiptID: readReceiptID, rootReadReceiptID: rootReadReceiptID,
                threadID: threadID)
            if newRows != rows { rows = newRows }
            lastEntries = entries
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

    /// Confirmed messages in server (ID) order, then unacknowledged sends in outbox order.
    /// Both runs are already ordered, so this is a concatenation, not a sort.
    private func timelineEntries() -> [ConversationTimelineEntry] {
        var confirmed = window.messages
        var earlyClientIDs: Set<String> = []
        if isBeforeInitialHistory {
            // Acknowledgements that arrived before the first page are shown in place.
            for (key, message) in deferredCreates where preHistoryAcknowledgementKeys.contains(key)
            {
                let index = confirmed.firstIndex { $0.id > message.id } ?? confirmed.count
                confirmed.insert(message, at: index)
                earlyClientIDs.insert(message.clientGeneratedId)
            }
        }
        let pending = messageStore.pending(chatID: chatID, threadID: threadID)
        var entries: [ConversationTimelineEntry] = []
        entries.reserveCapacity(confirmed.count + pending.count)
        entries.append(contentsOf: confirmed.lazy.map(ConversationTimelineEntry.remote))
        for item in pending {
            // A realtime echo can confirm a send before the outbox drops it from pending.
            guard window.index(of: .clientGenerated(item.clientGeneratedID)) == nil,
                !earlyClientIDs.contains(item.clientGeneratedID)
            else { continue }
            entries.append(.pending(item))
        }
        return entries
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
