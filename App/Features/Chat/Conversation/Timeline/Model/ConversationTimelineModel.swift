import Combine
import ChahuaAPI
import Foundation

enum TimelineInitialPosition: Equatable {
    case liveEdge
    case message(String)
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
    var isAtLiveEdge: Bool { window.isAtLiveEdge }
    let updates = CurrentValueSubject<TimelineHostSnapshot, Never>(.init(revision: 0, windowRevision: 0, rows: [], animateFollowing: false, pendingScroll: nil))

    private let source: any TimelineMessageSource
    private let messageStore: ConversationMessageStore
    private let builder: TimelineRowsBuilder
    private var window = TimelineWindow()
    private var observation: AnyCancellable?
    private var deferredCreates: [ConversationMessageStableKey: MessageResponse] = [:]
    private var preHistoryAcknowledgementKeys: Set<ConversationMessageStableKey> = []
    private var unseenKeys: Set<ConversationMessageStableKey> = []
    private var deletedIDs: Set<String> = []
    private var snapshotTokens: Set<UUID> = []
    private var generation = 0
    private var snapshotRevision = 0
    private var windowRevision = 0
    private var scrollRequestID = 0
    private var pendingScroll: TimelineScrollRequest?
    private var lastProjection: ConversationProjection?
    private var lastViewport = TimelineViewport.empty
    private var viewportRevision: Int?
    private var visibleAnchorID: String?
    private var lastInitialPosition: TimelineInitialPosition = .liveEdge
    private var initialTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var olderTask: Task<Void, Never>?
    private var newerTask: Task<Void, Never>?
    // A committed pending publication invalidates the host's viewport revision before reveal runs.
    private var canReuseLatestWindowAfterPendingChange = false

    init(chatID: String, currentUserID: Int32, isGroupChat: Bool, source: any TimelineMessageSource, messageStore: ConversationMessageStore, threadID: String? = nil, calendar: Calendar = .autoupdatingCurrent) {
        self.chatID = chatID
        self.threadID = threadID
        self.currentUserID = currentUserID
        self.source = source
        self.messageStore = messageStore
        builder = TimelineRowsBuilder(currentUserID: currentUserID, isGroupChat: isGroupChat, calendar: calendar)
        observeChanges()
        publish()
    }

    /// Unlike fixture-oriented loadInitial, every appearance requests a fresh latest window.
    func open() async {
        invalidateRequests()
        observeChanges()
        clearWindow()
        await loadInitial()
    }

    func close() {
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
                try await fetchSnapshot(query: aroundQuery(for: position), mode: .replace(latest: position == .liveEdge), generation: requestGeneration) {
                    self.state.content = .ready
                    switch position {
                    case .liveEdge:
                        self.state.live.followsLatest = true
                        self.publish(position: .bottom(animated: false), reset: true)
                    case .message(let id):
                        self.state.live.followsLatest = false
                        if let rowID = self.rowID(forServerID: id) { self.publish(position: .reveal(rowID, animated: false, highlight: true), reset: true) }
                        else { self.state.repositionFailure = .message(id); self.publish(position: .bottom(animated: false), reset: true) }
                    }
                }
            } catch is CancellationError {
                if generation == requestGeneration { state.content = .idle; publish() }
            } catch {
                if generation == requestGeneration { state.content = .initialLoadFailed; publish() }
            }
        }
        initialTask = task
        await task.value
    }

    func retryInitial() async { await loadInitial(position: lastInitialPosition) }

    func reconcileAfterReconnect() async {
        guard observation != nil else { return }
        if let initialTask { await initialTask.value; return }
        if let recoveryTask { await awaitRecovery(recoveryTask, generation: generation); return }
        if state.content == .idle || state.content == .initialLoadFailed { await loadInitial(); return }
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
                try await fetchSnapshot(query: anchor.map { self.aroundQuery(for: .message($0)) } ?? liveEdgeQuery, mode: .replace(latest: anchor == nil), generation: requestGeneration) {
                    self.state.reconciliationFailed = false
                    if let anchor {
                        self.state.live.followsLatest = false
                        let target = self.rowID(forServerID: anchor) ?? self.window.messages.first.flatMap { self.rowID(forServerID: $0.id) }
                        self.publish(position: target.map { .reveal($0, animated: false, highlight: false) }, reset: true)
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
        if case .repositioning(.liveEdge) = state.content { invalidateRequests(); state.content = .ready }
        if cancelledRequest {
            updates.send(.init(revision: snapshotRevision, windowRevision: windowRevision, rows: rows, animateFollowing: false, pendingScroll: nil))
        }
    }

    func viewportDidChange(_ viewport: TimelineViewport, reason: TimelineViewportChangeReason, revision: Int) {
        guard revision == snapshotRevision, viewport.isValid(forRowCount: rows.count) else { return }
        canReuseLatestWindowAfterPendingChange = false
        lastViewport = viewport
        viewportRevision = revision
        visibleAnchorID = nil
        if let first = viewport.firstVisibleIndex, let last = viewport.lastVisibleIndex {
            for index in first ... last where rows[index].messageID != nil {
                visibleAnchorID = rows[index].messageID
                break
            }
        }
        let pinned = viewport.distanceToBottom <= Self.pinnedToBottomTolerance
        var nextLive = state.live
        nextLive.isPinnedToBottom = pinned
        if reason == .user, pinned, isAtLiveEdge { nextLive.followsLatest = true }
        if pinned && isAtLiveEdge { unseenKeys.removeAll() }
        nextLive.unseenCount = unseenKeys.count
        if nextLive != state.live { state.live = nextLive }
        guard reason == .user, state.content == .ready, recoveryTask == nil else { return }
        let threshold = Self.edgePrefetchScreens * viewport.height
        if viewport.distanceToTop < threshold { loadEdge(.older) }
        if viewport.distanceToBottom < threshold { loadEdge(.newer) }
    }

    func scrollRequestDidFinish(id: Int) {
        guard pendingScroll?.id == id else { return }
        pendingScroll = nil
        updates.send(.init(revision: snapshotRevision, windowRevision: windowRevision, rows: rows, animateFollowing: false, pendingScroll: nil))
    }

    func jumpToLiveEdge() async {
        if recoveryTask != nil { invalidateRequests() }
        state.repositionFailure = nil
        state.reconciliationFailed = false
        if canReuseLatestWindow {
            state.live.followsLatest = true
            requestScroll(.bottom(animated: true))
            return
        }
        if case .repositioning(.liveEdge) = state.content { return }
        invalidateRequests()
        state.content = .repositioning(.liveEdge)
        let requestGeneration = generation
        do {
            try await fetchSnapshot(query: liveEdgeQuery, mode: .replace(latest: true), generation: requestGeneration) {
                state.content = .ready
                state.live.followsLatest = true
                publish(position: .bottom(animated: false), reset: true)
            }
        } catch is CancellationError {
            if generation == requestGeneration { state.content = .ready }
        } catch {
            if generation == requestGeneration { state.content = .ready; state.repositionFailure = .liveEdge }
        }
    }

    func dismissRepositionFailure() { state.repositionFailure = nil }

    func revealLatestAfterSend() async {
        let canReuse = canReuseLatestWindow || canReuseLatestWindowAfterPendingChange
        canReuseLatestWindowAfterPendingChange = false
        if state.content == .ready, canReuse {
            state.live.followsLatest = true
            publish(animateFollowing: true, position: .bottom(animated: true))
        } else if state.content == .ready || state.content == .repositioning(.liveEdge) {
            await jumpToLiveEdge()
        } else if state.content == .idle || state.content == .initialLoadFailed {
            await loadInitial()
        }
    }

    enum EdgeSide { case older, newer }
    func retryOlder() { state.older = .idle; loadEdge(.older) }
    func retryNewer() { state.newer = .idle; loadEdge(.newer) }

    private var canReuseLatestWindow: Bool {
        guard window.isAtLiveEdge, viewportRevision == snapshotRevision, lastViewport.isValid(forRowCount: rows.count), let last = lastViewport.lastVisibleIndex else { return false }
        return rows.indices.last.map { $0 - last <= Self.nearbyRowDistance } ?? true
    }

    private var visibleRemoteAnchor: String? {
        if let visibleAnchorID, window.index(ofServerID: visibleAnchorID) != nil { return visibleAnchorID }
        return window.messages.first?.id
    }

    private func loadEdge(_ side: EdgeSide) {
        guard state.content == .ready, recoveryTask == nil, edge(side) == .idle else { return }
        let query: ListMessagesQuery
        switch side {
        case .older: guard let cursor = window.olderCursor else { return }; query = .init(before: cursor, max: Self.pageSize, threadID: threadID)
        case .newer: guard let cursor = window.newerCursor else { return }; query = .init(after: cursor, max: Self.pageSize, threadID: threadID)
        }
        setEdge(side, .loading)
        let requestGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await fetchSnapshot(query: query, mode: .page(side), generation: requestGeneration) {
                    self.setEdge(side, .idle)
                    self.publish()
                }
            } catch is CancellationError { if generation == requestGeneration { setEdge(side, .idle) } }
            catch { if generation == requestGeneration { setEdge(side, .failed) } }
        }
        switch side { case .older: olderTask = task; case .newer: newerTask = task }
    }

    private enum SnapshotMode { case replace(latest: Bool), page(EdgeSide) }

    /// The baseline, ordered replay and caller's publication execute without a suspension.
    private func fetchSnapshot(query: ListMessagesQuery, mode: SnapshotMode, generation requestGeneration: Int, commit: () -> Void) async throws {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let token = messageStore.beginSnapshot(chatID: chatID)
        snapshotTokens.insert(token)
        defer { messageStore.endSnapshot(token); snapshotTokens.remove(token) }
        let page = try await source.fetchMessages(chatID: chatID, query: query)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let events = messageStore.eventsDuringSnapshot(token)
        switch mode {
        case .replace(let latest):
            window.replace(with: page, accepting: accepts)
            windowRevision &+= 1
            viewportRevision = nil
            lastViewport = .empty
            visibleAnchorID = nil
            pendingScroll = nil
            if latest { reconcileDeferredWithLatest() }
        case .page(.older): window.prependOlder(page, accepting: accepts)
        case .page(.newer): window.appendNewer(page, accepting: accepts)
        }
        preHistoryAcknowledgementKeys.removeAll()
        for event in events { reduce(event, replay: true) }
        absorbDeferredCreates()
        commit()
    }

    private func accepts(_ message: MessageResponse) -> Bool {
        guard message.chatId == chatID else { return false }
        if let threadID { return message.id == threadID || message.replyRootId == threadID }
        return message.replyRootId == nil
    }

    private func observeChanges() {
        guard observation == nil else { return }
        observation = messageStore.changes.sink { [weak self] change in self?.storeDidChange(change) }
    }

    private func storeDidChange(_ change: ConversationChange) {
        switch change {
        case .reset:
            invalidateRequests()
            clearWindow()
        case .pendingChanged(let changedChatID):
            guard changedChatID == chatID else { return }
            canReuseLatestWindowAfterPendingChange = canReuseLatestWindowAfterPendingChange || canReuseLatestWindow
            publish()
        case .realtime(let event):
            guard event.conversationChatID == chatID else { return }
            if isBeforeInitialHistory, case .message(let message) = event, accepts(message),
               lastProjection?.entries.contains(where: {
                   guard case .pending(let pending) = $0 else { return false }
                   return pending.clientGeneratedID == message.clientGeneratedId && pending.senderID == message.sender.uid
               }) == true {
                preHistoryAcknowledgementKeys.insert(message.timelineStableKey)
            }
            let appended = reduce(event, replay: false)
            publish(animateFollowing: !isBeforeInitialHistory && appended && state.live.followsLatest)
        }
    }

    private var isBeforeInitialHistory: Bool {
        state.content == .idle || state.content == .loadingInitial || state.content == .initialLoadFailed
    }

    /// Returns whether a genuinely new row was appended. Replay repairs data only.
    @discardableResult
    private func reduce(_ event: RealtimeServerEvent, replay: Bool) -> Bool {
        guard event.conversationChatID == chatID else { return false }
        switch event {
        case .message(let message):
            guard accepts(message), window.index(matching: message) == nil, deferredKey(matching: message) == nil,
                  replay || !deletedIDs.contains(message.id) else { return false }
            let content = deletedIDs.contains(message.id) ? message.redactedForDeletion() : message
            let message = content.redactingReplyPreview(messageIDs: deletedIDs)
            let outcome: TimelineWindow.LiveInsertOutcome
            if isBeforeInitialHistory && !replay { outcome = .deferred }
            else { outcome = window.insertLive(message) }
            if outcome == .deferred { deferredCreates[message.timelineStableKey] = message }
            if !replay, !isBeforeInitialHistory, outcome != .duplicate,
               outcome == .deferred || !state.live.followsLatest {
                unseenKeys.insert(message.timelineStableKey)
                state.live.unseenCount = unseenKeys.count
            }
            return outcome == .appended
        case .messageUpdated(let message):
            guard accepts(message) else { return false }
            mutateKnown(message) { existing in
                let updated = (existing.isDeleted || deletedIDs.contains(message.id)) ? message.redactedForDeletion() : message
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
            mutateServerID(payload.threadRootId) { $0.replacingThreadReplyCount(payload.replyCount) }
        case .pong, .chatArchiveStateChanged, .presenceUpdate, .threadMembershipChanged,
             .pinAdded, .threadPinAdded, .pinRemoved, .threadPinRemoved, .stickerPackOrderUpdated,
             .friendRequestReceived, .friendRequestResolved, .friendshipRemoved, .unknown:
            break
        }
        return false
    }

    private func deferredKey(matching message: MessageResponse) -> ConversationMessageStableKey? {
        deferredCreates.first(where: { $0.value.id == message.id })?.key
            ?? (message.clientGeneratedId.isEmpty || deferredCreates[message.timelineStableKey] == nil ? nil : message.timelineStableKey)
    }

    private func mutateKnown(_ message: MessageResponse, mutation: (MessageResponse) -> MessageResponse) {
        if let index = window.index(matching: message) { window.upsert(mutation(window.messages[index])) }
        if let key = deferredKey(matching: message), let existing = deferredCreates[key] {
            let updated = mutation(existing)
            deferredCreates.removeValue(forKey: key)
            deferredCreates[updated.timelineStableKey] = updated
        }
    }

    private func mutateServerID(_ id: String, mutation: (MessageResponse) -> MessageResponse) {
        if let index = window.index(ofServerID: id) { window.upsert(mutation(window.messages[index])) }
        if let entry = deferredCreates.first(where: { $0.value.id == id }) { deferredCreates[entry.key] = mutation(entry.value) }
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
        guard let newest = window.messages.last else { deferredCreates.removeAll(); return }
        deferredCreates = deferredCreates.filter {
            window.index(matching: $0.value) == nil && $0.value.createdAt >= newest.createdAt
        }
    }

    private func absorbDeferredCreates() {
        guard window.isAtLiveEdge else { return }
        for message in TimelineWindow.chronological(Array(deferredCreates.values)) { _ = window.insertLive(message) }
        deferredCreates.removeAll()
    }

    private func clearWindow() {
        window = TimelineWindow()
        windowRevision &+= 1
        deferredCreates.removeAll()
        preHistoryAcknowledgementKeys.removeAll()
        canReuseLatestWindowAfterPendingChange = false
        unseenKeys.removeAll()
        deletedIDs.removeAll()
        state = ConversationTimelineState()
        pendingScroll = nil
        lastViewport = .empty
        visibleAnchorID = nil
        viewportRevision = nil
        publish(reset: true)
    }

    private func invalidateRequests() {
        canReuseLatestWindowAfterPendingChange = false
        generation &+= 1
        initialTask?.cancel(); initialTask = nil
        recoveryTask?.cancel(); recoveryTask = nil
        olderTask?.cancel(); newerTask?.cancel(); olderTask = nil; newerTask = nil
        state.older = .idle; state.newer = .idle
        for token in snapshotTokens { messageStore.endSnapshot(token) }
        snapshotTokens.removeAll()
    }

    private func edge(_ side: EdgeSide) -> ConversationTimelineState.Edge { side == .older ? state.older : state.newer }
    private func setEdge(_ side: EdgeSide, _ value: ConversationTimelineState.Edge) { if side == .older { state.older = value } else { state.newer = value } }
    private var liveEdgeQuery: ListMessagesQuery { .init(max: Self.pageSize, threadID: threadID) }
    private func aroundQuery(for position: TimelineInitialPosition) -> ListMessagesQuery { if case .message(let id) = position { return .init(around: id, max: Self.pageSize, threadID: threadID) }; return liveEdgeQuery }
    private func rowID(forServerID id: String) -> TimelineRowID? { window.index(ofServerID: id).map { .message(window.messages[$0].timelineStableKey) } }

    private func publish(animateFollowing: Bool = false, position: TimelineScrollIntent? = nil, reset: Bool = false) {
        var remoteMessages = window.messages
        if isBeforeInitialHistory {
            for (key, message) in deferredCreates where preHistoryAcknowledgementKeys.contains(key) {
                remoteMessages.append(message)
            }
        }
        let projection = messageStore.projection(for: chatID, remoteMessages: remoteMessages, includePendingOutgoing: threadID == nil)
        let changed = projection != lastProjection || reset
        if changed {
            let newRows = builder.build(projection.entries)
            if newRows != rows { rows = newRows }
            lastProjection = projection
            snapshotRevision &+= 1
            viewportRevision = nil
        }
        if let position { issueScroll(position) }
        guard changed || position != nil else { return }
        updates.send(.init(revision: snapshotRevision, windowRevision: windowRevision, rows: rows, animateFollowing: animateFollowing, pendingScroll: pendingScroll))
    }

    private func requestScroll(_ intent: TimelineScrollIntent) { issueScroll(intent); updates.send(.init(revision: snapshotRevision, windowRevision: windowRevision, rows: rows, animateFollowing: false, pendingScroll: pendingScroll)) }
    private func issueScroll(_ intent: TimelineScrollIntent) { scrollRequestID &+= 1; pendingScroll = .init(id: scrollRequestID, intent: intent) }
}
