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
    private static let savedRefreshRetryLimit = 3

    let chatID: String
    let threadID: String?
    let currentUserID: Int32
    /// The thread root is a message; parsed once for per-message acceptance checks.
    private let threadRootID: MessageID?
    // Viewport-only changes belong to narrow chrome observers, not every observer
    // of this model (notably the conversation's composer and presentation tree).
    private(set) var state = ConversationTimelineState() {
        willSet {
            var previous = state
            previous.live.isPinnedToBottom = newValue.live.isPinnedToBottom
            previous.live.followsLatest = newValue.live.followsLatest
            previous.live.scrollsTowardNewer = newValue.live.scrollsTowardNewer
            if previous != newValue { objectWillChange.send() }
        }
        didSet {
            synchronizeViewportPresentation()
            if oldValue.content != state.content, state.content != .ready {
                selectionRange.clearDirection()
            }
        }
    }
    @Published private(set) var rows: [TimelineRow] = []
    let viewport = TimelineViewportPresentation()
    let selectionRange = TimelineSelectionRange()
    weak var selectionViewportSource: (any TimelineSelectionViewportSource)?
    private(set) var bottomVisibleMessageDate: Date? {
        didSet { synchronizeViewportPresentation() }
    }
    @Published private(set) var unreadMentionJumpCount = 0
    @Published private(set) var unreadReactionJumpCount = 0
    @Published private(set) var activityJumpInProgress = false
    var isAtLiveEdge: Bool { window.isAtLiveEdge }
    var jumpUnreadCount: Int64 { window.isSaved ? 0 : state.live.unreadCount }
    /// Selection survives pagination, but must discard messages deleted by realtime events.
    var knownDeletedMessageIDs: Set<MessageID> { deletedIDs }
    var showsJumpToLatest: Bool {
        state.content == .ready
            && ((window.isSaved ? state.newerSaved != nil : !isAtLiveEdge)
                || (viewportRevision == snapshotRevision && !state.live.isPinnedToBottom))
    }

    private func synchronizeViewportPresentation() {
        viewport.update(
            bottomVisibleMessageDate: bottomVisibleMessageDate,
            showsJumpToLatest: showsJumpToLatest)
    }
    let updates = CurrentValueSubject<TimelineHostSnapshot, Never>(
        .init(revision: 0, windowRevision: 0, rows: [], animateFollowing: false, pendingScroll: nil)
    )

    private let source: any TimelineMessageSource
    private let historyCache: AccountHistoryCache?
    private let canFetchHistory: @MainActor () -> Bool
    private let canRetryHistory: @MainActor () -> Bool
    private let sleepBeforeSavedRefreshRetry: @MainActor (Duration) async throws -> Void
    private var key: ConversationKey { .init(chatID: chatID, threadID: threadID) }
    private var historyCacheRevision: UInt64?
    private var historyPrivacyStamp: AccountHistoryCache.PrivacyStamp?
    private var windowSyncCertified = false
    var hasCurrentSyncTail: Bool {
        windowSyncCertified && window.isAtLiveEdge && state.content == .ready
            && !membershipRefreshRequired
            && historyPrivacyStamp == historyCache?.privacyStamp(chatID: chatID)
            && source.canPromoteCachedTail(key)
    }
    // Raw page edges include redacted/hidden messages and are never server cursors.
    private var savedBounds: ClosedRange<MessageID>?
    private var savedHidesMembership = false
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
    // Project known peer arrivals at the saved tail without extending its disk bounds.
    private var savedPeerTailKeys: Set<ConversationMessageStableKey> = []
    private var deletedIDs: Set<MessageID> = []
    private var snapshotTokens: Set<UUID> = []
    private var generation = 0
    private var snapshotRevision = 0
    private var windowRevision = 0
    private var scrollRequestID = 0
    private var pendingScroll: TimelineScrollRequest?
    private var lastEntries: [ConversationTimelineEntry]?
    private var lastViewport = TimelineViewport.empty
    private var rangeSelection: (anchors: TimelineSelectionRange.Edges, count: Int, busy: Bool)?
    private var rangeScrollReference: TimelineViewport?
    private var rangeCandidates:
        (revision: Int, messages: [MessageResponse], indices: [MessageID: Int])?
    private(set) var viewportRevision: Int? {
        didSet { synchronizeViewportPresentation() }
    }
    private var visibleAnchorID: MessageID?
    private var lastInitialPosition: TimelineInitialPosition = .liveEdge
    // A saved page can position the reader provisionally, but cannot settle an unread seek.
    private var needsServerUnreadSeek = false
    private var initialTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var initialIgnoresPath = false
    private var recoveryIgnoresPath = false
    private var recoveryIsAutomatic = false
    private var savedRefreshRetryTask: Task<Void, Never>?
    private var savedRefreshRetryAttempt = 0
    private var savedRefreshRetryDelay: Duration?
    private var olderTask: Task<Void, Never>?
    private var newerTask: Task<Void, Never>?
    private var linkPreviewExpiryTask: Task<Void, Never>?
    private var linkPreviewExpiry: Date?
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
    private var recordedReadTarget: MessageID?
    private var readCandidateMature = false
    private var readDwellTask: Task<Void, Never>?
    private var readSendTask: Task<Void, Never>?
    let isGroupChat: Bool
    private let fetchUnreadMentions:
        (@MainActor (String?) async throws -> UnreadMentionIDsResponse)?
    private let fetchUnreadReactions:
        (@MainActor (String?, String?) async throws -> UnreadReactionIDsResponse)?
    private let acknowledgeReactions:
        (@MainActor (String?, String?) async throws -> UnreadReactionsAckResponse)?
    private var mentionTargets: Set<MessageID> = []
    private var dismissedMentionTargets: Set<MessageID> = []
    private var reactionTargets: Set<MessageID> = []
    private var visitedReactionTargets: Set<MessageID> = []
    private var reactionReadThrough: String?
    private var reactionDwellTasks: [MessageID: Task<Void, Never>] = [:]
    private var reactionAckTask: Task<Void, Never>?
    private var reactionSessionEntered = false
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
        historyCache: AccountHistoryCache? = nil,
        canFetchHistory: @escaping @MainActor () -> Bool = { true },
        canRetryHistory: @escaping @MainActor () -> Bool = { true },
        sleepBeforeSavedRefreshRetry: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        markRead: (@MainActor (MessageID) async throws -> Void)? = nil,
        fetchReadReceipt: (@MainActor (String?) async throws -> MessageID?)? = nil,
        fetchUnreadMentions: (@MainActor (String?) async throws -> UnreadMentionIDsResponse)? = nil,
        fetchUnreadReactions: (
            @MainActor (String?, String?) async throws -> UnreadReactionIDsResponse
        )? =
            nil,
        acknowledgeReactions:
            (@MainActor (String?, String?) async throws -> UnreadReactionsAckResponse)? = nil
    ) {
        self.chatID = chatID
        self.threadID = threadID
        threadRootID = threadID.flatMap(MessageID.init)
        self.currentUserID = currentUserID
        self.source = source
        self.historyCache = historyCache
        self.canFetchHistory = canFetchHistory
        self.canRetryHistory = canRetryHistory
        self.sleepBeforeSavedRefreshRetry = sleepBeforeSavedRefreshRetry
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
        deletedIDs = messageStore.deletedMessageIDs(chatID: chatID)
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

    func historyPathChanged() {
        if !canFetchHistory() {
            pauseSavedRefreshRetry()
            if historyCache != nil, state.content == .ready, state.historyConnection != .refreshing
            {
                state.historyConnection = .offline
            }
        } else {
            scheduleSavedRefreshRetry()
        }
    }

    func setRealtimeStatus(_ status: RealtimeConnectionStatus) {
        historyPathChanged()
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
            cancelUnreadActivity()
            reactionReadThrough = nil
            visitedReactionTargets.removeAll()
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
        guard canTrackServerActivity, receiptTask == nil, receiptDirty != 0,
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

    /// Start a new request generation without blanking an already usable account window.
    func open(position: TimelineInitialPosition = .liveEdge) async {
        invalidateRequests()
        observeChanges()
        if let historyCache, historyCacheRevision == historyCache.revision,
            historyPrivacyStamp == historyCache.privacyStamp(chatID: chatID),
            state.content == .ready, !historyCache.accessRevoked(chatID)
        {
            deletedIDs.formUnion(messageStore.deletedMessageIDs(chatID: chatID))
            publish()
            if position == lastInitialPosition {
                await resumeNetworkHistory()
            } else {
                lastInitialPosition = position
                switch position {
                case .message(let id): await jumpToMessage(id)
                case .unread(.some(let id)): await jumpToMessage(id, atReadBoundary: true)
                case .liveEdge, .unread(nil): await jumpToLiveEdge(animated: false)
                }
            }
        } else {
            clearWindow()
            await loadInitial(position: position)
        }
    }

    func invalidateCachedHistory() {
        invalidateRequests()
        cancelReadReceipt(clear: true)
        resetUnreadActivity()
        clearWindow()
        guard historyCache?.isAvailable == true, !accountWasReset else { return }
        // No cache-derived rows survive a clear or revocation. Pending rows
        // still project through the shared message store.
        historyCacheRevision = historyCache?.revision
        historyPrivacyStamp = historyCache?.privacyStamp(chatID: chatID)
        installSavedHistory(nil, position: .liveEdge)
    }

    func resumeNetworkHistory() async {
        await reconcileAfterReconnect()
    }

    func retryNetworkHistory() async {
        guard canRetryHistory() else { return }
        await reconcileAfterReconnect(ignoringPath: true)
    }

    func close(acknowledgingActivity: Bool = false) {
        let shouldAcknowledge =
            acknowledgingActivity && reactionSessionEntered
            && !accountWasReset && !window.isSaved && canFetchHistory()
        let pendingAck = reactionAckTask
        setReadTrackingActive(false)
        cancelReadReceipt(clear: true)
        resetUnreadActivity()
        invalidateRequests()
        observation = nil
        windowSyncCertified = false
        linkPreviewExpiryTask?.cancel()
        linkPreviewExpiryTask = nil
        linkPreviewExpiry = nil
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
                await pendingAck?.value
                guard !Task.isCancelled, activityRevision == revision,
                    !accountWasReset, !window.isSaved, canFetchHistory()
                else { return }
                _ = try? await acknowledgeReactions(scope, nil)
            }
        }
    }

    func loadInitial(position: TimelineInitialPosition = .liveEdge) async {
        await loadInitial(position: position, ignoringPath: false)
    }

    private func loadInitial(position: TimelineInitialPosition, ignoringPath: Bool) async {
        guard !accountWasReset, state.content == .idle || state.content == .initialLoadFailed else {
            return
        }
        observeChanges()
        lastInitialPosition = position
        state.content = .loadingInitial
        publish()
        let requestGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration {
                    initialTask = nil
                    scheduleSavedRefreshRetry()
                    prefetchSavedEdges()
                }
            }
            do {
                let origin: CachedHistoryPosition
                switch position {
                case .message(let id), .unread(.some(let id)): origin = .around(id)
                case .liveEdge, .unread(nil): origin = .latest
                }
                let preferLatestWhenMissing: Bool
                if case .unread = position {
                    preferLatestWhenMissing = true
                } else {
                    preferLatestWhenMissing = false
                }
                if historyCache?.isAvailable == true {
                    let seeded = try await loadSavedPage(
                        origin, generation: requestGeneration,
                        preferLatestWhenMissing: preferLatestWhenMissing
                    ) { page, journal in
                        if case .unread(let after) = position,
                            ignoringPath || self.canFetchHistory(),
                            self.isUnverifiedLatestSeed(page),
                            after.map({ !self.savedPage(page, contains: $0) }) ?? true
                        {
                            return
                        }
                        self.installSavedHistory(page, position: position, journal: journal)
                    }
                    guard generation == requestGeneration else { return }
                    if !seeded { installSavedHistory(nil, position: position) }
                } else if !ignoringPath && !canFetchHistory() {
                    installSavedHistory(nil, position: position)
                }
                if window.isSaved, case .unread = position { needsServerUnreadSeek = true }
                guard ignoringPath || canFetchHistory(), historyCache?.accessRevoked(chatID) != true
                else { return }
                if window.isSaved {
                    await refreshDisplayedHistory(
                        generation: requestGeneration, ignoringPath: ignoringPath)
                    return
                }
                if case .unread(let after) = position {
                    try await loadUnreadEntry(
                        after: after, generation: requestGeneration, ignoringPath: ignoringPath)
                    return
                }
                if case .message(let id) = position {
                    try await loadMessageEntry(
                        id: id, generation: requestGeneration, ignoringPath: ignoringPath)
                    return
                }
                try await fetchSnapshot(
                    query: liveEdgeQuery, mode: .replace(latest: true),
                    generation: requestGeneration, ignoringPath: ignoringPath
                ) {
                    self.state.content = .ready
                    self.state.live.followsLatest = true
                    self.publish(position: .bottom(animated: false), reset: true)
                }
            } catch is CancellationError {
                if generation == requestGeneration, !window.isSaved {
                    state.content = .idle
                    publish()
                }
            } catch {
                if generation == requestGeneration, !Task.isCancelled {
                    if window.isSaved {
                        historyRefreshFailed(error)
                    } else {
                        state.content = .initialLoadFailed
                        publish()
                    }
                }
            }
        }
        initialIgnoresPath = ignoringPath
        initialTask = task
        await task.value
    }

    func retryInitial() async {
        await retryNetworkHistory()
    }

    /// Disk has the same ordered realtime journal as HTTP. Nothing read under an
    /// earlier generation, visibility policy or account epoch becomes visible.
    @discardableResult
    private func loadSavedPage(
        _ position: CachedHistoryPosition, generation requestGeneration: Int,
        preferLatestWhenMissing: Bool = false,
        commit: (CachedHistoryPage, [RealtimeServerEvent]) -> Void
    ) async throws -> Bool {
        guard let historyCache, historyCache.isAvailable,
            !historyCache.accessRevoked(chatID)
        else { return false }
        let cacheRevision = historyCache.revision
        let conversation = key
        let limit = Int(Self.pageSize)
        while true {
            let privacy = historyCache.privacyStamp(chatID: chatID)
            let token = messageStore.beginSnapshot(chatID: chatID)
            snapshotTokens.insert(token)
            defer {
                messageStore.endSnapshot(token)
                snapshotTokens.remove(token)
            }
            let page: CachedHistoryPage
            do {
                let candidate = try await historyCache.read {
                    try await $0.cachedHistory(conversation, position: position, limit: limit)
                }
                if preferLatestWhenMissing, case .around(let target) = position,
                    !savedPage(candidate, contains: target)
                {
                    page = try await historyCache.read {
                        try await $0.cachedHistory(conversation, position: .latest, limit: limit)
                    }
                } else {
                    page = candidate
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard generation == requestGeneration, historyCache.revision == cacheRevision,
                    !historyCache.accessRevoked(chatID)
                else { throw CancellationError() }
                return false
            }
            try Task.checkCancellation()
            guard generation == requestGeneration, historyCache.revision == cacheRevision,
                !historyCache.accessRevoked(chatID)
            else { throw CancellationError() }
            guard privacy == historyCache.privacyStamp(chatID: chatID),
                messageStore.membershipSnapshotIsCurrent(token)
            else { continue }
            historyCacheRevision = cacheRevision
            historyPrivacyStamp = privacy
            commit(page, messageStore.eventsDuringSnapshot(token))
            return true
        }
    }

    private func installSavedHistory(
        _ page: CachedHistoryPage?, position: TimelineInitialPosition,
        journal: [RealtimeServerEvent] = []
    ) {
        savedBounds = page.flatMap { savedRange(for: $0) }
        savedHidesMembership = page.map { savedPolicyHidesMembership($0) } ?? true
        let messages = page?.messages.filter(acceptsSaved) ?? []
        state.hasUnverifiedLatestSeed = page.map(isUnverifiedLatestSeed) ?? false
        let wasSaved = window.isSaved
        windowSyncCertified = false
        window.replaceSaved(with: messages)
        savedPeerTailKeys.removeAll()
        if !wasSaved {
            cancelReadReceipt(clear: true)
            resetUnreadActivity()
        }
        unreadBeforeMessageID = nil
        resetViewportForReplacement()
        state.olderSaved = savedEdge(page, side: .older)
        state.newerSaved = savedEdge(page, side: .newer)
        state.olderBoundaryIsKnownStart =
            page.map { !$0.messages.isEmpty && $0.syncOlderCursor == nil }
            ?? false
        if page?.context?.verifiedEmpty == true { state.olderBoundaryIsKnownStart = true }
        // The disk-read journal uses the new section's position, not the old viewport.
        switch position {
        case .message:
            state.live.followsLatest = false
        case .unread(let after):
            state.live.followsLatest =
                state.newerSaved == nil
                && savedUnreadBoundary(after: after) == nil
        case .liveEdge:
            state.live.followsLatest = state.newerSaved == nil
        }
        for event in journal { reduce(event, replay: true) }
        state.content = .ready
        state.history =
            if savedBounds != nil { .saved } else if page?.context?.verifiedEmpty == true {
                .verifiedEmpty
            } else { .notDownloaded }
        state.historyConnection = canFetchHistory() ? nil : .offline
        state.reconciliationFailed = false
        state.repositionFailure = nil
        state.missingOfflineMessage = nil
        let scroll: TimelineScrollIntent?
        switch position {
        case .message(let id):
            if let target = rowID(forServerID: id) {
                scroll = .reveal(target, animated: false, highlight: true)
            } else {
                state.missingOfflineMessage = id
                scroll = .bottom(animated: false)
            }
        case .unread(let after):
            unreadBeforeMessageID = savedUnreadBoundary(after: after)
            scroll =
                unreadBeforeMessageID == nil
                ? .bottom(animated: false)
                : .reveal(.unreadSeparator, animated: false, highlight: false)
            state.live.followsLatest = unreadBeforeMessageID == nil && state.newerSaved == nil
        case .liveEdge:
            scroll = .bottom(animated: false)
        }
        publish(position: scroll, reset: true)
    }

    private func isUnverifiedLatestSeed(_ page: CachedHistoryPage) -> Bool {
        page.messages.filter {
            acceptsSaved($0, hidingMembership: savedPolicyHidesMembership(page))
        }.count == 1
            && page.syncOlderCursor != nil && !page.syncLatest
            && !page.hasOlder && !page.hasNewer && !page.hasNewerSection
    }

    private func savedUnreadBoundary(after id: MessageID?) -> MessageID? {
        guard let id, let index = window.index(ofServerID: id),
            !window.messages[index].isDeleted, !deletedIDs.contains(id)
        else { return nil }
        return window.messages.dropFirst(index + 1).first {
            !$0.isDeleted && !deletedIDs.contains($0.id)
        }?.id
    }

    private func savedPolicyHidesMembership(_ page: CachedHistoryPage) -> Bool {
        page.context?.policy?.canView != true
            || page.context?.settings?.showMembershipMessages == false
    }

    private func savedPage(_ page: CachedHistoryPage, contains target: MessageID) -> Bool {
        guard !page.targetMissing, !deletedIDs.contains(target) else { return false }
        let hidesMembership = savedPolicyHidesMembership(page)
        return page.messages.contains {
            $0.id == target && !$0.isDeleted && acceptsSaved($0, hidingMembership: hidesMembership)
        }
    }

    private func savedRange(for page: CachedHistoryPage) -> ClosedRange<MessageID>? {
        guard let first = page.messages.first?.id, let last = page.messages.last?.id else {
            return nil
        }
        return first...last
    }

    private func savedEdge(
        _ page: CachedHistoryPage?, side: EdgeSide
    ) -> ConversationTimelineState.SavedEdge? {
        guard let page else { return nil }
        switch side {
        case .older: return page.hasOlder ? .more : page.hasOlderSection ? .section : nil
        case .newer: return page.hasNewer ? .more : page.hasNewerSection ? .section : nil
        }
    }

    /// Notifications and links can outlive their target. An unavailable anchor is
    /// not an empty conversation: open latest history and retain the missing-target banner.
    private func loadMessageEntry(
        id: MessageID, generation requestGeneration: Int, ignoringPath: Bool
    ) async throws {
        var needsLatest = false
        do {
            try await fetchSnapshot(
                query: aroundQuery(for: .message(id)), mode: .replace(latest: false),
                generation: requestGeneration, ignoringPath: ignoringPath,
                requiredMessageID: window.isSaved ? id : nil
            ) {}
            needsLatest = window.messages.isEmpty || isActivityTargetDeleted(id)
        } catch is MessageNotFound {
            needsLatest = true
        } catch let error as APIError {
            switch error {
            case .http(status: 404, body: _), .invalidResponse(statusCode: 404):
                needsLatest = true
            default:
                throw error
            }
        }
        if needsLatest {
            try await fetchSnapshot(
                query: liveEdgeQuery, mode: .replace(latest: true), generation: requestGeneration,
                ignoringPath: ignoringPath
            ) {}
        }
        state.content = .ready
        state.live.followsLatest = needsLatest
        if !needsLatest, let rowID = rowID(forServerID: id) {
            publish(position: .reveal(rowID, animated: false, highlight: true), reset: true)
        } else {
            state.repositionFailure = .message(id)
            publish(position: .bottom(animated: false), reset: true)
        }
    }

    private enum UnreadEntryError: Error { case stalledCursor }

    private func loadUnreadEntry(
        after lastReadID: MessageID?, generation requestGeneration: Int, ignoringPath: Bool
    ) async throws {
        if !hasAuthoritativeReadState, let lastReadID { advanceReadWatermark(to: lastReadID) }
        let query = lastReadID.map { aroundQuery(for: .message($0)) } ?? liveEdgeQuery
        let acceptsEntry: (ListMessagesResponse) -> Bool = { [self] _ in
            !window.isSaved || needsServerUnreadSeek
        }
        var fetchedLatest = lastReadID == nil
        do {
            try await fetchSnapshot(
                query: query, mode: .replace(latest: lastReadID == nil),
                generation: requestGeneration, ignoringPath: ignoringPath,
                acceptingResponse: acceptsEntry
            ) {}
        } catch let error as APIError {
            guard lastReadID != nil else { throw error }
            switch error {
            case .http(status: 404, body: _), .invalidResponse(statusCode: 404):
                try await fetchSnapshot(
                    query: liveEdgeQuery, mode: .replace(latest: true),
                    generation: requestGeneration, ignoringPath: ignoringPath,
                    acceptingResponse: acceptsEntry
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
                query: liveEdgeQuery, mode: .replace(latest: true), generation: requestGeneration,
                ignoringPath: ignoringPath
            ) {}
        }

        unreadBeforeMessageID = nil
        if let lastReadID, window.index(ofServerID: lastReadID) != nil {
            // Cursor presence affects seeking, not whether its read progress is known.
            var cursors: Set<MessageID> = []
            // An around page can end exactly at the read boundary.
            while window.messages.last?.id == lastReadID, let cursor = window.newerCursor {
                guard cursors.insert(cursor).inserted else { throw UnreadEntryError.stalledCursor }
                try await fetchSnapshot(
                    query: .init(after: cursor, max: Self.pageSize, threadID: threadID),
                    mode: .page(.newer), generation: requestGeneration, ignoringPath: ignoringPath
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
                    mode: .seekOlder, generation: requestGeneration, ignoringPath: ignoringPath
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
        recordedReadTarget = nil
        if historyCache != nil { viewportRevision = nil }
        updateReadCandidate()
    }

    private var canTrackServerActivity: Bool {
        readTrackingActive && !window.isSaved && !accountWasReset && canFetchHistory()
    }

    private func startTrackingServerActivity() {
        guard canTrackServerActivity else { return }
        reactionSessionEntered = true
        refreshReadReceipt(changed: false, mask: receiptMask & ~receiptFresh)
        refreshUnreadActivity(changed: false)
        completeReactionViewing()
    }

    func setReadTrackingActive(_ active: Bool) {
        if !active {
            pauseSavedRefreshRetry()
            cancelUnreadActivity()
            if activityJumpInProgress { invalidateRequests() }
        }
        guard !active || !accountWasReset else { return }
        guard readTrackingActive != active else { return }
        if active {
            reactionSessionEntered = !window.isSaved && canFetchHistory()
            activityRevision &+= 1
            leaveReactionTask?.cancel()
        }
        readTrackingActive = active
        if active {
            startTrackingServerActivity()
            scheduleSavedRefreshRetry()
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
        mentions: Bool = true, reactions: Bool = true, changed: Bool = true,
        reactionMessageID: MessageID? = nil
    ) {
        if let reactionMessageID {
            visitedReactionTargets.remove(reactionMessageID)
            reactionDwellTasks.removeValue(forKey: reactionMessageID)?.cancel()
        }
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
        guard mentionTask == nil, mentionsDirty, canTrackServerActivity,
            let fetchUnreadMentions
        else { return }
        let revision = activityRevision
        mentionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                mentionTask = nil
                if revision != activityRevision { startMentionRefresh() }
            }
            while canTrackServerActivity, revision == activityRevision, !Task.isCancelled,
                mentionsDirty
            {
                mentionsDirty = false
                do {
                    let response = try await fetchUnreadMentions(threadID)
                    guard canTrackServerActivity, revision == activityRevision, !Task.isCancelled
                    else {
                        return
                    }
                    mentionTargets.formUnion(
                        response.messageIds.lazy.filter {
                            !self.dismissedMentionTargets.contains($0)
                                && !self.isActivityTargetDeleted($0)
                        })
                    dismissVisibleActivityTargets()
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
        guard reactionTask == nil, reactionAckTask == nil, leaveReactionTask == nil,
            reactionsDirty, canTrackServerActivity, let fetchUnreadReactions
        else { return }
        let revision = activityRevision
        reactionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                reactionTask = nil
                if revision != activityRevision {
                    startReactionRefresh()
                } else {
                    completeReactionViewing()
                }
            }
            while canTrackServerActivity, revision == activityRevision, !Task.isCancelled,
                reactionsDirty
            {
                reactionsDirty = false
                do {
                    let response = try await fetchUnreadReactions(threadID, reactionReadThrough)
                    guard canTrackServerActivity, revision == activityRevision, !Task.isCancelled
                    else {
                        return
                    }
                    // A delta can contain a newer reaction on an already visited message.
                    for id in response.messageIds {
                        visitedReactionTargets.remove(id)
                        reactionDwellTasks.removeValue(forKey: id)?.cancel()
                        if isActivityTargetDeleted(id) {
                            visitedReactionTargets.insert(id)
                        } else {
                            reactionTargets.insert(id)
                        }
                    }
                    reactionReadThrough = response.readThrough
                    publishActivityCounts()
                    updateReactionDwell()
                    if !reactionsDirty { reactionsChanged = false }
                } catch {
                    guard revision == activityRevision, !Task.isCancelled else { return }
                    if !reactionsDirty {
                        reactionsDirty = true
                        return
                    }
                }
            }
        }
    }

    private func completeReactionViewing() {
        guard canTrackServerActivity, reactionSessionEntered, !reactionsDirty, !reactionsChanged,
            reactionTask == nil, reactionAckTask == nil, leaveReactionTask == nil,
            reactionTargets.isEmpty, !visitedReactionTargets.isEmpty,
            let boundary = reactionReadThrough, let acknowledgeReactions
        else { return }
        let revision = activityRevision
        reactionAckTask = Task { [weak self] in
            guard let self else { return }
            defer {
                reactionAckTask = nil
                // Notifications during the write wait for it before querying a delta.
                startReactionRefresh()
                if revision != activityRevision { completeReactionViewing() }
            }
            guard canTrackServerActivity, revision == activityRevision, !Task.isCancelled else {
                return
            }
            do {
                let response = try await acknowledgeReactions(threadID, boundary)
                guard canTrackServerActivity, revision == activityRevision, !Task.isCancelled else {
                    return
                }
                visitedReactionTargets.removeAll()
                // Keep reactionReadThrough: acknowledgement does not reset the query window.
                if response.unreadReactions > 0 {
                    reactionsDirty = true
                    reactionsChanged = true
                }
            } catch {
                // Retain the viewed targets and boundary; lifecycle reentry retries the write.
            }
        }
    }

    private func cancelReactionDwell() {
        for task in reactionDwellTasks.values { task.cancel() }
        reactionDwellTasks.removeAll()
    }

    private var visibleReactionTargets: Set<MessageID> {
        guard canTrackServerActivity, state.content == .ready, pendingScroll == nil,
            viewportRevision == snapshotRevision, lastViewport.isValid(forRowCount: rows.count)
        else { return [] }
        return reactionTargets.intersection(lastViewport.visibleReactionMessageIDs)
    }

    private func updateReactionDwell() {
        let visible = visibleReactionTargets
        for id in reactionDwellTasks.keys where !visible.contains(id) {
            reactionDwellTasks.removeValue(forKey: id)?.cancel()
        }
        let revision = activityRevision
        for id in visible where reactionDwellTasks[id] == nil {
            reactionDwellTasks[id] = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, revision == activityRevision, !Task.isCancelled,
                    visibleReactionTargets.contains(id)
                else { return }
                reactionDwellTasks.removeValue(forKey: id)
                dismissReactionTarget(id)
            }
        }
    }

    private func dismissReactionTarget(_ id: MessageID) {
        reactionDwellTasks.removeValue(forKey: id)?.cancel()
        visitedReactionTargets.insert(id)
        reactionTargets.remove(id)
        publishActivityCounts()
        completeReactionViewing()
    }

    private func cancelUnreadActivity() {
        activityRevision &+= 1
        cancelReactionDwell()
        if mentionTask != nil { mentionsDirty = true }
        if reactionTask != nil { reactionsDirty = true }
        // Keep cancelled tasks until their callbacks return: clients may ignore cancellation.
        mentionTask?.cancel()
        reactionTask?.cancel()
        leaveReactionTask?.cancel()
        reactionAckTask?.cancel()
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
        visitedReactionTargets.removeAll()
        reactionReadThrough = nil
        reactionSessionEntered = false
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
        visitedReactionTargets.formUnion(reactionTargets.intersection(ids))
        reactionTargets.subtract(ids)
        for id in ids { reactionDwellTasks.removeValue(forKey: id)?.cancel() }
        completeReactionViewing()
        publishActivityCounts()
    }

    /// Ordinary cursor reads dismiss mentions; reactions are independent viewport reads.
    private func dismissVisibleActivityTargets() {
        if let readWatermark {
            let mentions = mentionTargets.filter { $0 <= readWatermark }
            dismissedMentionTargets.formUnion(mentions)
            mentionTargets.subtract(mentions)
            publishActivityCounts()
        }
        updateReactionDwell()
    }

    func jumpToNextMention() async { await jumpToNextActivity(mention: true) }

    func jumpToNextReaction() async { await jumpToNextActivity(mention: false) }

    private func jumpToNextActivity(mention: Bool) async {
        guard canTrackServerActivity, !activityJumpInProgress else { return }
        activityJumpInProgress = true
        defer { activityJumpInProgress = false }
        let revision = activityRevision
        while canTrackServerActivity, revision == activityRevision,
            let id = (mention ? mentionTargets : reactionTargets).min()
        {
            let outcome = await jumpToMessage(id, atReactions: !mention)
            guard canTrackServerActivity, revision == activityRevision else { return }
            switch outcome {
            case .failed:
                return
            case .missing:
                if mention {
                    removeActivityTargets([id])
                } else {
                    dismissReactionTarget(id)
                }
            case .reached:
                if mention {
                    dismissedMentionTargets.insert(id)
                    mentionTargets.remove(id)
                } else {
                    if window.messages.first(where: { $0.id == id })?.reactions.isEmpty == true {
                        dismissReactionTarget(id)
                        continue
                    }
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
        // A path loss does not demote this server baseline to disk. Persist
        // ordinary visible reads; receipts and reaction activity still require HTTP.
        guard readTrackingActive, state.history == .server, !window.isSaved, !accountWasReset,
            historyCache != nil || canFetchHistory(), markRead != nil, observation != nil,
            state.content == .ready, pendingScroll == nil, viewportRevision == snapshotRevision,
            lastViewport.isValid(forRowCount: rows.count),
            let first = lastViewport.firstVisibleIndex, let last = lastViewport.lastVisibleIndex,
            let candidateID = lastViewport.visibleMessageIDs.last,
            candidateID != threadRootID
        else { return nil }
        for index in (first...last).reversed() {
            guard case .message(let row) = rows[index], let message = row.entry.remoteMessage,
                message.id == candidateID, message.id != recordedReadTarget,
                !message.isDeleted, !deletedIDs.contains(message.id),
                source.isPublishedReadTarget(message)
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
        dismissVisibleActivityTargets()
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
                    if self?.historyCache != nil {
                        self?.recordedReadTarget = candidate.id
                    } else {
                        self?.advanceReadWatermark(to: candidate.id)
                        self?.dismissVisibleActivityTargets()
                    }
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

    func reconcileAfterReconnect(ignoringPath: Bool = false) async {
        await reconcileAfterReconnect(ignoringPath: ignoringPath, automatic: false)
    }

    private func reconcileAfterReconnect(ignoringPath: Bool, automatic: Bool) async {
        guard !Task.isCancelled, observation != nil, !accountWasReset else { return }
        let incomingGeneration = generation
        if let initialTask {
            let mayNeedRetry = ignoringPath && !initialIgnoresPath
            await initialTask.value
            guard mayNeedRetry, !canFetchHistory(), generation == incomingGeneration,
                !Task.isCancelled
            else { return }
        }
        if let recoveryTask {
            let mayNeedRetry = ignoringPath && !recoveryIgnoresPath
            // Only the caller that starts a recovery owns its cancellation.
            await recoveryTask.value
            guard mayNeedRetry, !canFetchHistory(), generation == incomingGeneration,
                !Task.isCancelled
            else { return }
        }
        guard ignoringPath || canFetchHistory(), historyCache?.accessRevoked(chatID) != true else {
            if state.content == .idle, historyCache?.accessRevoked(chatID) != true {
                await loadInitial(position: lastInitialPosition)
            } else if state.content == .ready {
                state.historyConnection = .offline
            }
            return
        }
        if state.content == .idle || state.content == .initialLoadFailed {
            await loadInitial(position: lastInitialPosition, ignoringPath: ignoringPath)
            return
        }
        if membershipRefreshRequired, !window.isSaved {
            await reconcileMembershipVisibility(ignoringPath: ignoringPath)
            return
        }
        guard state.content == .ready else { return }
        guard !hasCurrentSyncTail else { return }
        invalidateRequests(keepingSavedRefreshRetryBudget: automatic)
        state.reconciliationFailed = false
        let requestGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration {
                    recoveryTask = nil
                    recoveryIsAutomatic = false
                    scheduleSavedRefreshRetry()
                    prefetchSavedEdges()
                }
            }
            await refreshDisplayedHistory(generation: requestGeneration, ignoringPath: ignoringPath)
        }
        recoveryIgnoresPath = ignoringPath
        recoveryIsAutomatic = automatic
        recoveryTask = task
        await awaitRecovery(task, generation: requestGeneration)
    }

    private func refreshDisplayedHistory(generation requestGeneration: Int, ignoringPath: Bool)
        async
    {
        let wasSaved = window.isSaved
        if wasSaved || ignoringPath { state.historyConnection = .refreshing }
        publish()
        do {
            try await source.waitForTimelineSync()
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            if hasCurrentSyncTail {
                state.historyConnection = nil
                return
            }
            if try await promoteCachedTail(generation: requestGeneration) { return }
            if needsServerUnreadSeek, case .unread(let after) = lastInitialPosition {
                do {
                    try await loadUnreadEntry(
                        after: after, generation: requestGeneration, ignoringPath: ignoringPath)
                    needsServerUnreadSeek = false
                    return
                } catch is RecoveryAnchorMoved {
                    // The reader moved on the saved page. Refresh around their viewport below.
                }
            }
            if let missing = state.missingOfflineMessage {
                try await loadMessageEntry(
                    id: missing, generation: requestGeneration, ignoringPath: ignoringPath)
                return
            }
            while true {
                let requestedAnchor = recoveryAnchor(saved: wasSaved)
                var acceptedAnchor = requestedAnchor
                var placement = pendingScroll?.intent
                let savedUnread = unreadBeforeMessageID
                do {
                    try await fetchSnapshot(
                        query: requestedAnchor.map { aroundQuery(for: .message($0)) }
                            ?? liveEdgeQuery,
                        mode: .replace(latest: requestedAnchor == nil),
                        generation: requestGeneration,
                        ignoringPath: ignoringPath,
                        preservingSavedOnEmpty: wasSaved && requestedAnchor != nil,
                        acceptingResponse: { page in
                            guard wasSaved else { return true }
                            acceptedAnchor = recoveryAnchor(saved: true)
                            placement = pendingScroll?.intent
                            guard acceptedAnchor != requestedAnchor else { return true }
                            // A reader who moves during a fetch keeps their current row.
                            // If the page cannot preserve it, seek again from the new viewport.
                            guard let acceptedAnchor else { return false }
                            return page.messages.contains {
                                $0.id == acceptedAnchor && !$0.isDeleted
                            }
                        },
                        commit: {
                            state.reconciliationFailed = false
                            state.live.followsLatest = acceptedAnchor == nil
                            if wasSaved {
                                unreadBeforeMessageID = savedUnread.flatMap {
                                    rowID(forServerID: $0) == nil ? nil : $0
                                }
                            }
                            let position: TimelineScrollIntent?
                            if let acceptedAnchor {
                                if wasSaved, rowID(forServerID: acceptedAnchor) != nil {
                                    // Native hosts compensate a surviving stable row's offset.
                                    position = placement
                                } else {
                                    let target =
                                        rowID(forServerID: acceptedAnchor)
                                        ?? window.messages.first.flatMap {
                                            rowID(forServerID: $0.id)
                                        }
                                    position = target.map {
                                        .reveal($0, animated: false, highlight: false)
                                    }
                                }
                            } else {
                                position = .bottom(animated: false)
                            }
                            publish(position: position, reset: true)
                        })
                    return
                } catch is RecoveryAnchorMoved {
                    continue
                }
            }
        } catch {
            guard generation == requestGeneration else { return }
            if Task.isCancelled || error is CancellationError {
                if state.historyConnection == .refreshing {
                    state.historyConnection = canFetchHistory() ? nil : .offline
                }
            } else {
                historyRefreshFailed(error)
            }
        }
    }

    private func promoteCachedTail(generation requestGeneration: Int) async throws -> Bool {
        guard source.canPromoteCachedTail(key), state.missingOfflineMessage == nil,
            !membershipRefreshRequired || window.isSaved
        else { return false }
        let requestedAnchor = recoveryAnchor(saved: window.isSaved)
        var promoted = false
        try await loadSavedPage(
            requestedAnchor.map(CachedHistoryPosition.around) ?? .latest,
            generation: requestGeneration
        ) { page, journal in
            guard page.syncLatest, source.canPromoteCachedTail(key) else { return }
            if let anchor = recoveryAnchor(saved: window.isSaved),
                !savedPage(page, contains: anchor)
            {
                return
            }
            if needsServerUnreadSeek {
                switch lastInitialPosition {
                case .unread(.some(let after)):
                    guard savedPage(page, contains: after) else { return }
                case .unread(nil):
                    guard page.messages.isEmpty else { return }
                default: break
                }
            }
            let hidingMembership = savedPolicyHidesMembership(page)
            window.replace(with: .init(messages: page.messages, olderCursor: page.syncOlderCursor))
            {
                self.acceptsSaved($0, hidingMembership: hidingMembership)
            }
            savedBounds = nil
            savedHidesMembership = false
            savedPeerTailKeys.removeAll()
            preHistoryAcknowledgementKeys.removeAll()
            state.olderSaved = nil
            state.newerSaved = nil
            state.olderBoundaryIsKnownStart = page.syncOlderCursor == nil
            for event in journal { reduce(event, replay: true) }
            // Arrivals are now in the ordered cache or the journal, not the saved overlay.
            deferredCreates.removeAll()
            if needsServerUnreadSeek, case .unread(let after) = lastInitialPosition {
                unreadBeforeMessageID = savedUnreadBoundary(after: after)
            }
            needsServerUnreadSeek = false
            membershipRefreshRequired = false
            membershipRefreshLowerBound = nil
            membershipRefreshUpperBound = nil
            membershipRefreshAtLiveEdge = false
            windowSyncCertified = true
            state.history = .server
            state.hasUnverifiedLatestSeed = false
            state.historyConnection = nil
            state.reconciliationFailed = false
            publish()
            startTrackingServerActivity()
            promoted = true
        }
        return promoted
    }

    private func historyRefreshFailed(_ error: any Error) {
        state.historyConnection = canFetchHistory() ? nil : .offline
        state.reconciliationFailed = true
        guard window.isSaved, savedRefreshRetryAttempt < Self.savedRefreshRetryLimit,
            let error = error as? APIError
        else { return }
        switch error {
        case .transport(let transportError):
            guard transportError.code != .cancelled else { return }
        case .unavailable, .retryableHTTP:
            break
        case .http(let status, _), .invalidResponse(let status):
            guard status == 408 || status == 429 || (500...599).contains(status) else { return }
        default:
            return
        }
        savedRefreshRetryDelay = .seconds(
            max(savedRefreshBackoff, error.retryAfter?.timeIntervalSinceNow ?? 0))
    }

    private var savedRefreshBackoff: Double {
        Double(1 << savedRefreshRetryAttempt)
    }

    private var canAutomaticallyRetrySavedHistory: Bool {
        readTrackingActive && observation != nil && !accountWasReset && window.isSaved
            && state.content == .ready && state.reconciliationFailed && canFetchHistory()
            && historyCache?.isAvailable == true && historyCache?.revision == historyCacheRevision
            && historyCache?.accessRevoked(chatID) != true
    }

    private func scheduleSavedRefreshRetry() {
        guard canAutomaticallyRetrySavedHistory, savedRefreshRetryTask == nil,
            initialTask == nil, recoveryTask == nil,
            let delay = savedRefreshRetryDelay
        else { return }
        let requestGeneration = generation
        savedRefreshRetryTask = Task { [weak self, sleepBeforeSavedRefreshRetry] in
            do { try await sleepBeforeSavedRefreshRetry(delay) } catch { return }
            guard let self, !Task.isCancelled, generation == requestGeneration else { return }
            // Give disk paging priority, then choose the current visible anchor.
            while state.older == .loading || state.newer == .loading {
                if state.older == .loading { await olderTask?.value }
                if state.newer == .loading { await newerTask?.value }
                guard !Task.isCancelled, generation == requestGeneration else { return }
            }
            savedRefreshRetryTask = nil
            guard canAutomaticallyRetrySavedHistory else { return }
            savedRefreshRetryDelay = nil
            savedRefreshRetryAttempt += 1
            await reconcileAfterReconnect(ignoringPath: false, automatic: true)
        }
    }

    private func pauseSavedRefreshRetry() {
        savedRefreshRetryTask?.cancel()
        savedRefreshRetryTask = nil
        if recoveryIsAutomatic, recoveryTask?.isCancelled == false {
            recoveryTask?.cancel()
            state.reconciliationFailed = true
            if savedRefreshRetryAttempt < Self.savedRefreshRetryLimit {
                savedRefreshRetryDelay = .seconds(savedRefreshBackoff)
            }
        }
    }

    private func recoveryAnchor(saved: Bool) -> MessageID? {
        if (saved || window.isAtLiveEdge) && state.live.followsLatest { return nil }
        if saved, pendingScroll != nil, case .message(let id) = lastInitialPosition {
            return id
        }
        return visibleRemoteAnchor
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
    private func reconcileMembershipVisibility(ignoringPath: Bool) async {
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
                        generation: requestGeneration, ignoringPath: ignoringPath
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
                        generation: requestGeneration, ignoringPath: ignoringPath
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
        recoveryIgnoresPath = ignoringPath
        recoveryTask = task
        await awaitRecovery(task, generation: requestGeneration)
    }

    private func cancelServerUnreadSeek() {
        guard needsServerUnreadSeek else { return }
        needsServerUnreadSeek = false
        if initialTask != nil || recoveryTask != nil { invalidateRequests() }
    }

    func userScrollBegan() {
        if window.isSaved {
            needsServerUnreadSeek = false
        } else {
            cancelServerUnreadSeek()
        }
        canReuseLatestWindowAfterPendingChange = false
        if state.live.followsLatest { state.live.followsLatest = false }
        let cancelledRequest = pendingScroll != nil
        pendingScroll = nil
        if (!window.isSaved && recoveryTask != nil)
            || (window.isSaved && state.historyConnection == .refreshing
                && state.missingOfflineMessage != nil)
        {
            invalidateRequests()
        }
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

    func canSelectMessage(_ message: MessageResponse) -> Bool {
        message.chatId == chatID && !message.isDeleted && message.messageType != .system
            && !deletedIDs.contains(message.id)
    }

    func updateSelectionRange(
        active: Bool, ids: Dictionary<MessageID, MessageResponse>.Keys, busy: Bool
    ) {
        guard active else {
            rangeSelection = nil
            rangeScrollReference = nil
            rangeCandidates = nil
            selectionRange.clearDirection()
            return
        }
        let starting = rangeSelection == nil
        rangeSelection = (.init(older: ids.min(), newer: ids.max()), ids.count, busy)
        if starting {
            selectionRange.clearDirection()
            if viewportRevision == snapshotRevision {
                trackSelectionRange(lastViewport, reason: .programmatic)
            }
        } else {
            refreshSelectionRange()
        }
    }

    func selectionRangeMessages(
        toward direction: TimelineSelectionRange.Direction, visibleIDs: [MessageID]
    ) -> ArraySlice<MessageResponse>? {
        guard canOfferSelectionRange, direction == selectionRange.direction else { return nil }
        prepareRangeCandidates()
        selectionRange.edges = selectionEdges(in: visibleIDs)
        guard let selection = rangeSelection, let candidates = rangeCandidates,
            let interval = selectionInterval(
                toward: direction, edge: selectionRange.edges[direction]),
            interval.count <= TimelineSelectionRange.limit - selection.count
        else {
            refreshSelectionRange()
            return nil
        }
        selectionRange.clearDirection()
        return candidates.messages[interval]
    }

    private var canOfferSelectionRange: Bool {
        rangeSelection?.busy == false && state.content == .ready && pendingScroll == nil
    }

    private func prepareRangeCandidates() {
        guard rangeCandidates?.revision != snapshotRevision else { return }
        var messages: [MessageResponse] = []
        var indices: [MessageID: Int] = [:]
        // Rows are in server order. Use the rendered remote rows, not pending
        // sends or records the timeline has suppressed in favor of a pending row.
        for case .message(let row) in rows {
            guard let message = row.entry.remoteMessage, canSelectMessage(message) else { continue }
            if window.isSaved, savedPeerTailKeys.contains(message.timelineStableKey) { continue }
            indices[message.id] = messages.count
            messages.append(message)
        }
        rangeCandidates = (snapshotRevision, messages, indices)
    }

    private func selectionEdges(in visibleIDs: [MessageID]) -> TimelineSelectionRange.Edges {
        guard let indices = rangeCandidates?.indices else { return .init() }
        return .init(
            older: visibleIDs.first { indices[$0] != nil },
            newer: visibleIDs.last { indices[$0] != nil })
    }

    private func selectionInterval(
        toward direction: TimelineSelectionRange.Direction, edge: MessageID?
    ) -> Range<Int>? {
        guard let anchor = rangeSelection?.anchors[direction], let edge,
            let indices = rangeCandidates?.indices,
            let anchorIndex = indices[anchor], let edgeIndex = indices[edge],
            window.index(ofServerID: anchor) != nil, window.index(ofServerID: edge) != nil
        else { return nil }
        switch direction {
        case .older: return edgeIndex < anchorIndex ? edgeIndex..<anchorIndex : nil
        case .newer: return edgeIndex > anchorIndex ? (anchorIndex + 1)..<(edgeIndex + 1) : nil
        }
    }

    private func refreshSelectionRange() {
        guard canOfferSelectionRange,
            let selection = rangeSelection, let direction = selectionRange.direction,
            let interval = selectionInterval(
                toward: direction, edge: selectionRange.edges[direction])
        else {
            selectionRange.present(nil)
            return
        }
        selectionRange.present(
            .init(
                direction: direction, count: interval.count,
                remaining: TimelineSelectionRange.limit - selection.count))
    }

    private func trackSelectionRange(
        _ viewport: TimelineViewport, reason: TimelineViewportChangeReason
    ) {
        guard rangeSelection != nil else { return }
        prepareRangeCandidates()
        selectionRange.edges = selectionEdges(in: viewport.visibleMessageIDs)
        defer { refreshSelectionRange() }

        let extent = viewport.distanceToTop + viewport.distanceToBottom
        let previous = rangeScrollReference
        let comparable =
            previous.map {
                $0.height == viewport.height
                    && abs(extent - $0.distanceToTop - $0.distanceToBottom) < 0.5
            } ?? false
        // A layout read can see the new offset before the user-scroll report.
        // Do not consume that movement, but do rebase if layout changed the scroll extent.
        if reason != .layout || !comparable { rangeScrollReference = viewport }
        guard reason == .user, pendingScroll == nil else { return }
        let delta =
            viewport.userScrollDelta
            ?? (comparable ? viewport.distanceToTop - (previous?.distanceToTop ?? 0) : 0)
        guard delta != 0 else { return }
        let newer = delta > 0
        selectionRange.updateDirection(
            for: newer ? .newer : .older,
            previous: previous.map { selectionEdges(in: $0.visibleMessageIDs) } ?? .init(),
            reachedEdge: (newer ? viewport.distanceToBottom : viewport.distanceToTop) < 1,
            canExtend: { selectionInterval(toward: $0, edge: $1) != nil })
    }

    func viewportDidChange(
        _ viewport: TimelineViewport, reason: TimelineViewportChangeReason, revision: Int
    ) {
        if revision == snapshotRevision, !viewport.isValid(forRowCount: rows.count) {
            viewportRevision = nil
            state.olderEdgeIsVisible = false
            selectionRange.present(nil)
            rangeScrollReference = nil
            selectionRange.edges = .init()
            cancelReadCandidate()
            cancelReactionDwell()
        }
        guard revision == snapshotRevision, viewport.isValid(forRowCount: rows.count) else {
            return
        }
        canReuseLatestWindowAfterPendingChange = false
        let previousAnchorID = visibleAnchorID
        lastViewport = viewport
        state.olderEdgeIsVisible =
            pendingScroll == nil && viewport.distanceToTop <= Self.pinnedToBottomTolerance
        if viewportRevision != revision { viewportRevision = revision }
        trackSelectionRange(viewport, reason: reason)
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
        guard state.content == .ready, recoveryTask == nil else { return }
        if reason == .user {
            // A queued reveal does not disable user-driven paging. Only automatic
            // local filling waits for navigation to settle in prefetchSavedEdges().
            let threshold = Self.edgePrefetchScreens * viewport.height
            if viewport.distanceToTop < threshold { loadEdge(.older) }
            if viewport.distanceToBottom < threshold { loadEdge(.newer) }
        } else {
            prefetchSavedEdges()
        }
    }

    /// Layout can fill a short cached window, but must never initiate HTTP pagination.
    /// Each installation needs a current host measurement; hidden-only pages can reuse it.
    private func prefetchSavedEdges() {
        guard state.content == .ready, initialTask == nil, recoveryTask == nil,
            pendingScroll == nil, viewportRevision == snapshotRevision,
            lastViewport.isValid(forRowCount: rows.count),
            window.isSaved || !canFetchHistory()
        else { return }
        let threshold = Self.edgePrefetchScreens * lastViewport.height
        if lastViewport.distanceToTop < threshold { loadSavedEdge(.older) }
        if lastViewport.distanceToBottom < threshold { loadSavedEdge(.newer) }
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
        if !window.isSaved, threadID == nil, jumpUnreadCount > 0,
            let lastReadMessageID, !isAtOrBeyondReadBoundary
        {
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
        cancelServerUnreadSeek()
        if recoveryTask != nil { invalidateRequests() }
        state.repositionFailure = nil
        state.reconciliationFailed = false
        state.missingOfflineMessage = nil
        if !canFetchHistory() {
            if window.isSaved, state.newerSaved == nil {
                state.live.followsLatest = true
                requestScroll(.bottom(animated: animated))
                return
            }
            invalidateRequests()
            let requestGeneration = generation
            _ = try? await loadSavedPage(.latest, generation: requestGeneration) { page, journal in
                if !page.messages.isEmpty || page.context?.verifiedEmpty == true {
                    installSavedHistory(page, position: .liveEdge, journal: journal)
                }
            }
            return
        }
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
    func jumpToMessage(
        _ id: MessageID, atReadBoundary: Bool = false, atReactions: Bool = false
    ) async
        -> TimelineMessageJumpOutcome
    {
        switch state.content {
        case .ready, .repositioning: break
        default: return .failed
        }
        cancelServerUnreadSeek()
        selectionRange.clearDirection()
        invalidateRequests()
        state.repositionFailure = nil
        state.missingOfflineMessage = nil
        state.content = .ready
        if isActivityTargetDeleted(id) {
            if !canFetchHistory() {
                state.missingOfflineMessage = id
            } else {
                state.repositionFailure = .message(id)
            }
            return .missing
        }
        if let rowID = rowID(forServerID: id) {
            state.live.followsLatest = false
            requestScroll(
                atReadBoundary
                    ? .readBoundary(rowID, animated: true)
                    : atReactions
                        ? .reaction(rowID, animated: true, highlight: true)
                        : .reveal(rowID, animated: true, highlight: true))
            return .reached
        }
        if !canFetchHistory() {
            let requestGeneration = generation
            _ = try? await loadSavedPage(.around(id), generation: requestGeneration) {
                page, journal in
                guard savedPage(page, contains: id) else { return }
                installSavedHistory(page, position: .message(id), journal: journal)
            }
            guard generation == requestGeneration else { return .failed }
            if rowID(forServerID: id) != nil { return .reached }
            state.missingOfflineMessage = id
            return .missing
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
                            : atReactions
                                ? .reaction(rowID, animated: false, highlight: true)
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

    func dismissRepositionFailure() {
        state.repositionFailure = nil
        state.missingOfflineMessage = nil
    }

    // Reveal a locally available tail immediately. History networking must not
    // keep the composer submitting after its durable enqueue has completed.
    func revealLatestAfterSend() {
        let canReuse = canReuseLatestWindow || canReuseLatestWindowAfterPendingChange
        canReuseLatestWindowAfterPendingChange = false
        if state.content == .ready, canReuse || window.isSaved || !canFetchHistory() {
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
        if window.isSaved {
            if state.older == .failed { state.older = .idle }
            loadSavedEdge(.older)
        } else if canRetryHistory() {
            state.older = .idle
            loadEdge(.older, ignoringPath: true)
        }
    }
    func retryNewer() {
        if window.isSaved {
            if state.newer == .failed { state.newer = .idle }
            loadSavedEdge(.newer)
        } else if canRetryHistory() {
            state.newer = .idle
            loadEdge(.newer, ignoringPath: true)
        }
    }

    private var canReuseLatestWindow: Bool {
        guard window.isAtLiveEdge, viewportRevision == snapshotRevision,
            lastViewport.isValid(forRowCount: rows.count), let last = lastViewport.lastVisibleIndex
        else { return false }
        return rows.indices.last.map { $0 - last <= Self.nearbyRowDistance } ?? true
    }

    private var visibleRemoteAnchor: MessageID? {
        if let visibleAnchorID, rowID(forServerID: visibleAnchorID) != nil {
            return visibleAnchorID
        }
        return window.messages.first { !$0.isDeleted && !deletedIDs.contains($0.id) }?.id
    }

    private func loadEdge(_ side: EdgeSide, ignoringPath: Bool = false) {
        guard state.content == .ready, recoveryTask == nil, edge(side) == .idle else { return }
        if window.isSaved || (!ignoringPath && !canFetchHistory()) {
            loadSavedEdge(side)
            return
        }
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
                    query: query, mode: .page(side), generation: requestGeneration,
                    ignoringPath: ignoringPath
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

    private func loadSavedEdge(_ side: EdgeSide) {
        guard state.content == .ready, recoveryTask == nil, initialTask == nil,
            state.older != .loading, state.newer != .loading, edge(side) == .idle,
            historyCache?.isAvailable == true
        else { return }
        let bounds =
            savedBounds
            ?? window.messages.first.flatMap { first in
                window.messages.last.map { first.id...$0.id }
            }
        guard let bounds else { return }
        let direction =
            window.isSaved
            ? (side == .older ? state.olderSaved : state.newerSaved)
            : .more
        let position: CachedHistoryPosition
        switch (side, direction) {
        case (.older, .some(.more)): position = .before(bounds.lowerBound)
        case (.newer, .some(.more)): position = .after(bounds.upperBound)
        default: return
        }
        setEdge(side, .loading)
        let requestGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration {
                    if edge(side) == .loading { setEdge(side, .idle) }
                    if side == .older { olderTask = nil } else { newerTask = nil }
                    prefetchSavedEdges()
                }
            }
            do {
                let accepted = try await loadSavedPage(position, generation: requestGeneration) {
                    page, journal in
                    self.mergeSavedPage(
                        page, journal: journal, side: side, previousBounds: bounds)
                }
                if generation == requestGeneration, !accepted { setEdge(side, .failed) }
            } catch {
                if generation == requestGeneration { setEdge(side, .idle) }
            }
        }
        if side == .older { olderTask = task } else { newerTask = task }
    }

    private func mergeSavedPage(
        _ page: CachedHistoryPage, journal: [RealtimeServerEvent], side: EdgeSide,
        previousBounds: ClosedRange<MessageID>
    ) {
        let wasHidingMembership = window.isSaved && hidesSavedMembership
        savedHidesMembership = savedPolicyHidesMembership(page)
        if !window.isSaved {
            cancelReadReceipt(clear: true)
            resetUnreadActivity()
            state.olderSaved = .more
            state.newerSaved = .more
        }
        let existing = savedBounds ?? previousBounds
        if let incoming = savedRange(for: page) {
            savedBounds =
                min(
                    existing.lowerBound, incoming.lowerBound)...max(
                    existing.upperBound, incoming.upperBound)
        } else {
            savedBounds = existing
        }
        let accepted = page.messages.filter(acceptsSaved)
        if !wasHidingMembership, hidesSavedMembership {
            window.removeAll { $0.systemKind?.isMembership == true }
        }
        window.mergeSaved(accepted)
        state.hasUnverifiedLatestSeed = false
        for event in journal { reduce(event, replay: true) }
        state.history = .saved
        state.historyConnection = canFetchHistory() ? nil : .offline
        let progressed =
            side == .older
            ? (savedBounds?.lowerBound ?? existing.lowerBound) < existing.lowerBound
            : (savedBounds?.upperBound ?? existing.upperBound) > existing.upperBound
        // A cache policy change or empty page must not re-read the same bound indefinitely.
        let next = savedEdge(page, side: side)
        if side == .older {
            state.olderSaved = progressed || next != .more ? next : nil
            state.olderBoundaryIsKnownStart =
                !page.messages.isEmpty && page.syncOlderCursor == nil
        } else {
            state.newerSaved = progressed || next != .more ? next : nil
        }
        publish()
    }

    private enum SnapshotMode {
        case replace(latest: Bool)
        case page(EdgeSide)
        case seekOlder
        case membershipRange(lower: MessageID, upper: MessageID?)
    }

    private struct MessageNotFound: Error {}
    private struct RecoveryAnchorMoved: Error {}

    /// The baseline, ordered replay and caller's publication execute without a suspension.
    @discardableResult
    private func fetchSnapshot(
        query: ListMessagesQuery, mode: SnapshotMode, generation requestGeneration: Int,
        ignoringPath: Bool = false,
        requiredMessageID: MessageID? = nil, preservingSavedOnEmpty: Bool = false,
        acceptingResponse: (ListMessagesResponse) -> Bool = { _ in true },
        commit: () -> Void
    ) async throws -> MessageID? {
        let cacheRevision = historyCache?.revision
        while true {
            try Task.checkCancellation()
            guard generation == requestGeneration, ignoringPath || canFetchHistory(),
                !accountWasReset,
                historyCache?.accessRevoked(chatID) != true
            else { throw CancellationError() }
            let token = messageStore.beginSnapshot(chatID: chatID)
            let pageToken = historyCache?.startPage(key)
            snapshotTokens.insert(token)
            defer {
                messageStore.endSnapshot(token)
                snapshotTokens.remove(token)
                if let pageToken { historyCache?.finishPage(pageToken) }
            }
            let fetched = try await source.fetchMessages(
                chatID: chatID, query: query, ignoringPath: ignoringPath)
            let page = fetched.response
            try Task.checkCancellation()
            guard generation == requestGeneration, cacheRevision == historyCache?.revision,
                ignoringPath || canFetchHistory(), historyCache?.accessRevoked(chatID) != true
            else { throw CancellationError() }
            // Settings can change while returning from the source, even after its own
            // response fence has passed. A retry starts its own journal and page serial.
            if isGroupChat, threadID == nil, !messageStore.membershipSnapshotIsCurrent(token) {
                continue
            }
            guard acceptingResponse(page) else { throw RecoveryAnchorMoved() }
            if let requiredMessageID,
                !page.messages.contains(where: {
                    $0.id == requiredMessageID && acceptsServer($0)
                })
            {
                throw MessageNotFound()
            }
            if preservingSavedOnEmpty, !page.messages.contains(where: acceptsServer) {
                throw MessageNotFound()
            }
            let events = messageStore.eventsDuringSnapshot(token, after: fetched.journalFloor)
            let wasSaved = window.isSaved
            installServerPage(page, mode: mode)
            savedPeerTailKeys.removeAll()
            preHistoryAcknowledgementKeys.removeAll()
            for event in events { reduce(event, replay: true) }
            absorbDeferredCreates()
            historyCacheRevision = cacheRevision
            historyPrivacyStamp = historyCache?.privacyStamp(chatID: chatID)
            state.history = .server
            state.hasUnverifiedLatestSeed = false
            state.historyConnection = nil
            state.missingOfflineMessage = nil
            if let pageToken {
                // Preserve HTTP coverage exactly. Journal-only creates must not
                // stretch its bounds; the writer replays those events in the same transaction.
                let baseline: ListMessagesResponse
                if page.messages.allSatisfy(acceptsServer) {
                    baseline = page
                } else {
                    baseline = .init(
                        messages: page.messages.filter(acceptsServer),
                        olderCursor: page.olderCursor,
                        newerCursor: page.newerCursor, nextCursor: page.nextCursor,
                        prevCursor: page.prevCursor,
                        membershipMessagePolicy: page.membershipMessagePolicy,
                        chatSettings: page.chatSettings)
                }
                let write = historyCache?.acceptPage(
                    pageToken, query: query, response: baseline,
                    journal: messageStore.cacheEventsDuringSnapshot(
                        token, after: fetched.journalFloor), at: fetched.at)
                if fetched.at != nil, query.before == nil, page.newerCursor == nil, let write {
                    let revision = windowRevision
                    Task { [weak self] in
                        guard (try? await write.value) == true, let self,
                            self.generation == requestGeneration, self.windowRevision == revision,
                            self.window.isAtLiveEdge, self.source.canPromoteCachedTail(self.key)
                        else { return }
                        self.windowSyncCertified = true
                    }
                }
            }
            commit()
            if wasSaved { startTrackingServerActivity() }
            return page.newerCursor
        }
    }

    private func installServerPage(_ page: ListMessagesResponse, mode: SnapshotMode) {
        switch mode {
        case .replace(let latest):
            windowSyncCertified = false
            if window.isSaved {
                membershipRefreshRequired = false
                membershipRefreshLowerBound = nil
                membershipRefreshUpperBound = nil
                membershipRefreshAtLiveEdge = false
            }
            window.replace(with: page, accepting: acceptsServer)
            savedHidesMembership = false
            savedBounds = nil
            state.olderSaved = nil
            state.newerSaved = nil
            resetViewportForReplacement()
            if latest { reconcileDeferredWithLatest() }
        case .seekOlder:
            windowSyncCertified = false
            // Seeking the oldest page must not retain the entire conversation.
            // An empty terminal page still leaves the previous accessible page usable.
            if page.messages.isEmpty {
                window.prependOlder(page, accepting: acceptsServer)
            } else {
                window.replace(with: page, accepting: acceptsServer)
            }
        case .page(.older): window.prependOlder(page, accepting: acceptsServer)
        case .page(.newer): window.appendNewer(page, accepting: acceptsServer)
        case .membershipRange(let lower, let upper):
            window.mergePreservingCursors(page) { message in
                message.id >= lower && (upper.map { message.id <= $0 } ?? true)
                    && self.acceptsServer(message)
            }
        }
        state.olderBoundaryIsKnownStart = window.olderCursor == nil
    }

    private func accepts(_ message: MessageResponse) -> Bool {
        window.isSaved ? acceptsSaved(message) : acceptsServer(message)
    }

    private var hidesSavedMembership: Bool {
        isGroupChat
            && (savedHidesMembership || messageStore.hidesMembershipMessages(chatID: chatID))
    }

    private func acceptsSaved(_ message: MessageResponse) -> Bool {
        acceptsSaved(message, hidingMembership: savedHidesMembership)
    }

    private func acceptsSaved(_ message: MessageResponse, hidingMembership: Bool) -> Bool {
        acceptsServer(message)
            && !(isGroupChat && message.systemKind?.isMembership == true
                && (hidingMembership || messageStore.hidesMembershipMessages(chatID: chatID)))
    }

    private func acceptsServer(_ message: MessageResponse) -> Bool {
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
            accountWasReset = true
            cancelReadReceipt(clear: true)
            invalidateRequests()
            clearWindow()
        case .syncHistoryInvalidated(let changedChatID, let purge):
            guard changedChatID == chatID else { return }
            windowSyncCertified = false
            if purge { invalidateCachedHistory() }
        case .membershipVisibilityChanged(let changedChatID):
            guard isGroupChat,
                changedChatID == nil || changedChatID == chatID
            else { return }
            // Root visibility can also redact embedded quotes in a thread.
            if threadID != nil {
                if window.isSaved, hidesSavedMembership {
                    window.removeAll { $0.systemKind?.isMembership == true }
                }
                publish()
                return
            }
            let lower = window.messages.first?.id
            windowSyncCertified = false
            let upper = window.messages.last?.id
            membershipRefreshAtLiveEdge = membershipRefreshAtLiveEdge || window.isAtLiveEdge
            if let lower {
                membershipRefreshLowerBound = min(membershipRefreshLowerBound ?? lower, lower)
            }
            if let upper {
                membershipRefreshUpperBound = max(membershipRefreshUpperBound ?? upper, upper)
            }
            membershipRefreshRequired = true
            if window.isSaved, messageStore.hidesMembershipMessages(chatID: chatID) {
                if state.olderSaved != nil { state.olderSaved = .section }
                if state.newerSaved != nil { state.newerSaved = .section }
            }
            let hidden = Set(
                window.messages.lazy.filter { !self.accepts($0) }.map(\.id))
            if !hidden.isEmpty { window.removeAll { hidden.contains($0.id) } }
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
            guard event.conversationChatID == chatID, !accountWasReset,
                historyCache?.accessRevoked(chatID) != true
            else { return }
            if isBeforeInitialHistory || window.isSaved, case .message(let message) = event,
                accepts(message),
                lastEntries?.contains(where: {
                    guard case .pending(let pending) = $0 else { return false }
                    return pending.clientGeneratedID == message.clientGeneratedId
                        && pending.senderID == message.sender.uid
                        && pending.chatID == message.chatId
                        && pending.threadID == message.replyRootId
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
            if message.isDeleted {
                recordDeletion(message)
            }
            guard accepts(message),
                replay || message.isDeleted || !deletedIDs.contains(message.id)
            else { return false }
            let inWindow = window.index(matching: message) != nil
            let deferred = inWindow ? nil : deferredKey(matching: message)
            let visibleShell =
                message.replyRootId == nil && (message.threadInfo?.replyCount ?? 0) > 0
            // A peer create is socket ingress; only own creates can come from local
            // settlement. A thread's root is not a new arrival in that thread.
            let showsSavedPeer =
                window.isSaved && state.live.followsLatest && state.newerSaved == nil
                && message.sender.uid != currentUserID && message.replyRootId == threadID
                && (!message.isDeleted && !deletedIDs.contains(message.id) || visibleShell)
                && !inWindow
                && (savedBounds.map { message.id > $0.upperBound } ?? true)
            let addedAtSavedTail =
                showsSavedPeer
                && savedPeerTailKeys.insert(deferred ?? message.timelineStableKey).inserted
            if inWindow || deferred != nil {
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
                return addedAtSavedTail
            }
            let content = deletedIDs.contains(message.id) ? message.redactedForDeletion() : message
            let message = content.redactingReplyPreview(messageIDs: deletedIDs)
            if !isBeforeInitialHistory, window.insertWithinRange(message) { return false }
            if window.isSaved, !showsSavedPeer,
                !preHistoryAcknowledgementKeys.contains(message.timelineStableKey)
            {
                return false
            }
            let outcome: TimelineWindow.LiveInsertOutcome
            if window.isSaved || (isBeforeInitialHistory && !replay) {
                outcome = .deferred
            } else {
                outcome = window.insertLive(message)
            }
            if outcome == .deferred { deferredCreates[message.timelineStableKey] = message }
            return outcome == .appended || addedAtSavedTail
        case .messageUpdated(let message):
            guard accepts(message) else { return false }
            mutateKnown(message) { existing in
                let updated =
                    (existing.isDeleted || deletedIDs.contains(message.id))
                    ? message.redactedForDeletion() : message
                return updated.redactingReplyPreview(messageIDs: deletedIDs)
            }
        case .messageDeleted(let message):
            recordDeletion(message)
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
            .membershipMessagePolicyChanged, .chatMembershipChanged, .chatSettingsChanged,
            .conversationUnread, .conversationUnreadError, .conversationStates,
            .conversationStatesError,
            .messageSyncHello, .messageSyncBatch, .messageSyncReady, .messageSyncReset,
            .messageSyncRevoked, .messageSyncPageResult, .messageSyncResumed,
            .pinAdded, .threadPinAdded, .pinRemoved, .threadPinRemoved, .stickerPackOrderUpdated,
            .friendRequestReceived, .friendRequestResolved, .friendshipRemoved, .unknown:
            break
        }
        return false
    }

    private func recordDeletion(_ message: MessageResponse) {
        deletedIDs.insert(message.id)
        removeActivityTargets([message.id])
        if accepts(message) { mutateKnown(message) { _ in message.redactedForDeletion() } }
        redactDeletedPreviews([message.id])
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
            if updated.timelineStableKey != key, savedPeerTailKeys.remove(key) != nil {
                savedPeerTailKeys.insert(updated.timelineStableKey)
            }
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
        needsServerUnreadSeek = false
        let unreadCount = state.live.unreadCount
        let realtimeStatus = state.realtimeStatus
        window = TimelineWindow()
        savedBounds = nil
        savedHidesMembership = false
        historyCacheRevision = nil
        historyPrivacyStamp = nil
        windowSyncCertified = false
        unreadBeforeMessageID = nil
        hasSentEntryRead = false
        deferredCreates.removeAll()
        preHistoryAcknowledgementKeys.removeAll()
        savedPeerTailKeys.removeAll()
        canReuseLatestWindowAfterPendingChange = false
        deletedIDs = messageStore.deletedMessageIDs(chatID: chatID)
        membershipRefreshRequired = false
        membershipRefreshLowerBound = nil
        membershipRefreshUpperBound = nil
        membershipRefreshAtLiveEdge = false
        state = ConversationTimelineState(realtimeStatus: realtimeStatus)
        state.live.unreadCount = unreadCount
        resetViewportForReplacement()
        publish(reset: true)
    }

    private func resetViewportForReplacement() {
        windowRevision &+= 1
        pendingScroll = nil
        lastViewport = .empty
        bottomVisibleMessageDate = nil
        visibleAnchorID = nil
        viewportRevision = nil
        state.olderEdgeIsVisible = false
    }

    private func invalidateRequests(keepingSavedRefreshRetryBudget: Bool = false) {
        canReuseLatestWindowAfterPendingChange = false
        cancelReadCandidate()
        cancelReactionDwell()
        readSendTask?.cancel()
        viewportRevision = nil
        generation &+= 1
        savedRefreshRetryTask?.cancel()
        savedRefreshRetryTask = nil
        savedRefreshRetryDelay = nil
        if !keepingSavedRefreshRetryBudget { savedRefreshRetryAttempt = 0 }
        initialTask?.cancel()
        initialTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryIsAutomatic = false
        olderTask?.cancel()
        newerTask?.cancel()
        olderTask = nil
        newerTask = nil
        state.older = .idle
        state.newer = .idle
        if state.historyConnection == .refreshing {
            state.historyConnection = canFetchHistory() ? nil : .offline
        }
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
        guard !deletedIDs.contains(id) else { return nil }
        if let index = window.index(ofServerID: id), !window.messages[index].isDeleted {
            return .message(window.messages[index].timelineStableKey)
        }
        if window.isSaved, !savedPeerTailKeys.isEmpty,
            let message = deferredCreates.first(where: {
                $0.value.id == id && !$0.value.isDeleted && savedPeerTailKeys.contains($0.key)
            })?.value
        {
            return .message(message.timelineStableKey)
        }
        return nil
    }

    private func publish(
        animateFollowing: Bool = false, position: TimelineScrollIntent? = nil, reset: Bool = false
    ) {
        defer { synchronizeViewportPresentation() }
        let pendingLiveCount = window.isSaved ? 0 : deferredCreates.count
        if state.live.pendingLiveCount != pendingLiveCount {
            state.live.pendingLiveCount = pendingLiveCount
        }
        let entries = timelineEntries()
        scheduleLinkPreviewExpiry(in: entries)
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
            state.olderEdgeIsVisible = false
            if selectionRange.direction != nil {
                prepareRangeCandidates()
                refreshSelectionRange()
            }
            cancelReadCandidate()
            cancelReactionDwell()
        }
        if let position { issueScroll(position) }
        guard changed || position != nil else { return }
        updates.send(
            .init(
                revision: snapshotRevision, windowRevision: windowRevision, rows: rows,
                animateFollowing: animateFollowing, pendingScroll: pendingScroll))
    }

    /// A single local wakeup removes expired skeletons even when no server event arrives.
    /// This never fetches previews or mutates the authoritative message/cache.
    private func scheduleLinkPreviewExpiry(in entries: [ConversationTimelineEntry]) {
        let now = Date()
        var next: Date?
        for entry in entries {
            guard let message = entry.remoteMessage, !message.isDeleted,
                let previews = message.metadata?.linkPreviews
            else { continue }
            for preview in previews where preview.status == .pending {
                guard let expiry = preview.expiresAt, expiry > now else { continue }
                if next.map({ expiry < $0 }) ?? true { next = expiry }
            }
        }
        guard next != linkPreviewExpiry else { return }
        linkPreviewExpiryTask?.cancel()
        linkPreviewExpiry = next
        linkPreviewExpiryTask = nil
        guard let next else { return }
        linkPreviewExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            linkPreviewExpiry = nil
            linkPreviewExpiryTask = nil
            publish()
        }
    }

    /// Confirmed messages stay in server order; unsubmitted work follows in FIFO order.
    private func timelineEntries() -> [ConversationTimelineEntry] {
        var confirmed = window.messages
        if isBeforeInitialHistory || window.isSaved,
            !preHistoryAcknowledgementKeys.isEmpty || !savedPeerTailKeys.isEmpty
        {
            // Project settlements and socket arrivals without turning saved rows into a live edge.
            for (key, message) in deferredCreates
            where
                (preHistoryAcknowledgementKeys.contains(key) || savedPeerTailKeys.contains(key))
                && window.index(matching: message) == nil
            {
                let index = confirmed.firstIndex { $0.id > message.id } ?? confirmed.count
                confirmed.insert(message, at: index)
            }
        }
        let pending = messageStore.pending(chatID: chatID, threadID: threadID)
        let pendingKeys = Set(pending.lazy.map { ConversationTimelineEntry.pending($0).stableKey })
        var entries: [ConversationTimelineEntry] = []
        entries.reserveCapacity(confirmed.count + pending.count)
        let now = Date()
        let hidesMembership =
            isGroupChat
            && ((window.isSaved && savedHidesMembership)
                || messageStore.hidesMembershipMessages(chatID: chatID))
        for message in confirmed {
            // An ordinary ingress with the exact local identity cannot remove a durable row.
            if !pendingKeys.isEmpty, pendingKeys.contains(message.timelineStableKey) { continue }
            var content =
                !message.isDeleted && deletedIDs.contains(message.id)
                ? message.redactedForDeletion() : message
            if hidesMembership, content.replyToMessage?.systemKind?.isMembership == true {
                content = content.removingReplyPreview()
            }
            entries.append(
                .remote(
                    content.redactingReplyPreview(messageIDs: deletedIDs)
                        .projectingExpiredLinkPreviews(at: now)))
        }
        for item in pending {
            if hidesMembership, item.replyToMessage?.systemKind?.isMembership == true {
                var redacted = item
                redacted.replyToMessage = nil
                entries.append(.pending(redacted))
            } else {
                entries.append(.pending(item))
            }
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
        selectionRange.clearDirection()
        rangeScrollReference = nil
        cancelReadCandidate()
        cancelReactionDwell()
        viewportRevision = nil
        scrollRequestID &+= 1
        pendingScroll = .init(id: scrollRequestID, intent: intent)
    }
}
