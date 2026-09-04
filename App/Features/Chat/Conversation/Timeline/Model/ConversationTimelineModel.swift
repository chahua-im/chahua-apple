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
    @Published private(set) var state = ConversationTimelineState()
    @Published private(set) var rows: [TimelineRow] = []
    var isAtLiveEdge: Bool { window.isAtLiveEdge }
    let updates = CurrentValueSubject<TimelineHostSnapshot, Never>(.init(revision: 0, windowRevision: 0, rows: [], animateFollowing: false, pendingScroll: nil))

    private let source: any TimelineMessageSource
    private let messageStore: ConversationMessageStore
    private let builder: TimelineRowsBuilder
    private var window = TimelineWindow()
    private var storeRevision: AnyCancellable?
    private var generation = 0
    private var snapshotRevision = 0
    private var windowRevision = 0
    private var scrollRequestID = 0
    private var pendingScroll: TimelineScrollRequest?
    private var lastProjection: ConversationProjection?
    private var lastViewport = TimelineViewport.empty
    private var viewportRevision: Int?
    private var lastInitialPosition: TimelineInitialPosition = .liveEdge
    private var olderTask: Task<Void, Never>?
    private var newerTask: Task<Void, Never>?

    init(chatID: String, currentUserID: Int32, isGroupChat: Bool, source: any TimelineMessageSource, messageStore: ConversationMessageStore, threadID: String? = nil, calendar: Calendar = .autoupdatingCurrent) {
        self.chatID = chatID
        self.threadID = threadID
        self.source = source
        self.messageStore = messageStore
        builder = TimelineRowsBuilder(currentUserID: currentUserID, isGroupChat: isGroupChat, calendar: calendar)
        storeRevision = messageStore.$revision.dropFirst().sink { [weak self] _ in self?.storeDidChange() }
    }

    func loadInitial(position: TimelineInitialPosition = .liveEdge) async {
        guard state.content == .idle || state.content == .initialLoadFailed else { return }
        lastInitialPosition = position
        state.content = .loadingInitial
        let requestGeneration = bumpGeneration()
        do {
            let page = try await source.fetchMessages(chatID: chatID, query: position == .liveEdge ? liveEdgeQuery : aroundQuery(for: position))
            guard generation == requestGeneration else { return }
            installWindow(page)
            state.content = .ready
            switch position {
            case .liveEdge:
                state.live.followsLatest = true
                publish(position: .bottom(animated: false), reset: true)
            case .message(let id):
                state.live.followsLatest = false
                if let rowID = rowID(forServerID: id) { publish(position: .reveal(rowID, animated: false, highlight: true), reset: true) }
                else { state.repositionFailure = .message(id); publish(position: .bottom(animated: false), reset: true) }
            }
        } catch is CancellationError {
            guard generation == requestGeneration else { return }; state.content = .idle
        } catch {
            guard generation == requestGeneration else { return }; state.content = .initialLoadFailed
        }
    }

    func retryInitial() async { await loadInitial(position: lastInitialPosition) }
    func userScrollBegan() {
        state.live.followsLatest = false
        let cancelledRequest = pendingScroll != nil
        pendingScroll = nil
        if case .repositioning(.liveEdge) = state.content { _ = bumpGeneration(); state.content = .ready }
        if cancelledRequest {
            updates.send(.init(revision: snapshotRevision, windowRevision: windowRevision, rows: rows, animateFollowing: false, pendingScroll: nil))
        }
    }

    func viewportDidChange(_ viewport: TimelineViewport, reason: TimelineViewportChangeReason, revision: Int) {
        guard revision == snapshotRevision, viewport.isValid(forRowCount: rows.count) else { return }
        lastViewport = viewport
        viewportRevision = revision
        let pinned = viewport.distanceToBottom <= Self.pinnedToBottomTolerance
        var nextLive = state.live
        nextLive.isPinnedToBottom = pinned
        if reason == .user, pinned, isAtLiveEdge { nextLive.followsLatest = true }
        if pinned && isAtLiveEdge { nextLive.unseenCount = 0 }
        if nextLive != state.live { state.live = nextLive }
        guard reason == .user, state.content == .ready else { return }
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
        state.repositionFailure = nil
        if canReuseLatestWindow {
            state.live.followsLatest = true
            requestScroll(.bottom(animated: true))
            return
        }
        if case .repositioning(.liveEdge) = state.content { return }
        cancelEdgeLoads()
        state.content = .repositioning(.liveEdge)
        let requestGeneration = bumpGeneration()
        do {
            let page = try await source.fetchMessages(chatID: chatID, query: liveEdgeQuery)
            guard generation == requestGeneration else { return }
            installWindow(page)
            state.content = .ready
            state.live.followsLatest = true
            publish(position: .bottom(animated: false), reset: true)
        } catch is CancellationError {
            guard generation == requestGeneration else { return }; state.content = .ready
        } catch {
            guard generation == requestGeneration else { return }; state.content = .ready; state.repositionFailure = .liveEdge
        }
    }

    func dismissRepositionFailure() { state.repositionFailure = nil }

    func enqueue(_ pending: PendingOutgoingMessage) async {
        let canReuse = canReuseLatestWindow
        writingStore { messageStore.enqueue(pending) }
        if state.content == .ready, canReuse {
            state.live.followsLatest = true
            publish(animateFollowing: true, position: .bottom(animated: true))
        } else if state.content == .ready || state.content == .repositioning(.liveEdge) {
            await jumpToLiveEdge()
        } else if state.content == .idle || state.content == .initialLoadFailed {
            await loadInitial()
        }
    }

    func receiveLive(_ message: MessageResponse) {
        writingStore { messageStore.receiveLive(message) }
        switch window.insertLive(message) {
        case .deferred: state.live.unseenCount += 1
        case .updated: publish()
        case .appended:
            if state.live.followsLatest { publish(animateFollowing: true) }
            else { state.live.unseenCount += 1; publish() }
        }
    }

    enum EdgeSide { case older, newer }
    func retryOlder() { state.older = .idle; loadEdge(.older) }
    func retryNewer() { state.newer = .idle; loadEdge(.newer) }

    private var canReuseLatestWindow: Bool {
        guard window.isAtLiveEdge, viewportRevision == snapshotRevision, lastViewport.isValid(forRowCount: rows.count), let last = lastViewport.lastVisibleIndex else { return false }
        return rows.indices.last.map { $0 - last <= Self.nearbyRowDistance } ?? true
    }

    private func loadEdge(_ side: EdgeSide) {
        guard state.content == .ready, edge(side) == .idle else { return }
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
                let page = try await source.fetchMessages(chatID: chatID, query: query)
                guard generation == requestGeneration else { return }
                switch side { case .older: window.prependOlder(page); case .newer: window.appendNewer(page) }
                setEdge(side, .idle); publish()
            } catch is CancellationError { if generation == requestGeneration { setEdge(side, .idle) } }
            catch { if generation == requestGeneration { setEdge(side, .failed) } }
        }
        switch side { case .older: olderTask = task; case .newer: newerTask = task }
    }

    private func edge(_ side: EdgeSide) -> ConversationTimelineState.Edge { side == .older ? state.older : state.newer }
    private func setEdge(_ side: EdgeSide, _ value: ConversationTimelineState.Edge) { if side == .older { state.older = value } else { state.newer = value } }
    private func cancelEdgeLoads() { olderTask?.cancel(); newerTask?.cancel(); olderTask = nil; newerTask = nil; state.older = .idle; state.newer = .idle }
    private var liveEdgeQuery: ListMessagesQuery { .init(max: Self.pageSize, threadID: threadID) }
    private func aroundQuery(for position: TimelineInitialPosition) -> ListMessagesQuery { if case .message(let id) = position { return .init(around: id, max: Self.pageSize, threadID: threadID) }; return liveEdgeQuery }
    private func rowID(forServerID id: String) -> TimelineRowID? { window.index(ofServerID: id).map { .message(window.messages[$0].timelineStableKey) } }

    private func installWindow(_ page: ListMessagesResponse) {
        window.replace(with: page); windowRevision &+= 1; viewportRevision = nil; lastViewport = .empty
        guard let newest = window.messages.last else { return }
        writingStore { messageStore.reconcileDeferredLive(chatID: chatID, installedKeys: window.stableKeys, newestCreatedAt: newest.createdAt) }
    }
    private func bumpGeneration() -> Int { generation &+= 1; return generation }
    private var isWritingStore = false
    private func writingStore(_ body: () -> Void) { isWritingStore = true; defer { isWritingStore = false }; body() }
    private func storeDidChange() { guard !isWritingStore else { return }; if state.content == .ready || state.content == .repositioning(.liveEdge) { publish() } }

    private func publish(animateFollowing: Bool = false, position: TimelineScrollIntent? = nil, reset: Bool = false) {
        absorbDeferredLive()
        let projection = messageStore.projection(for: chatID, remoteMessages: window.messages, includePendingOutgoing: true)
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
    private func absorbDeferredLive() {
        guard window.isAtLiveEdge else { return }
        let deferred = messageStore.deferredLiveMessages(chatID: chatID)
        guard !deferred.isEmpty else { return }
        window.mergeLive(deferred)
        let keys = Set(deferred.map(\.timelineStableKey)).intersection(window.stableKeys)
        if !keys.isEmpty { writingStore { messageStore.consumeDeferredLive(chatID: chatID, projectedKeys: keys) } }
    }
}
