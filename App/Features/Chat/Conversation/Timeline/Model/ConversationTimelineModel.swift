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
    /// Derived from the window's cursors. Every window mutation is followed by `publish`,
    /// which sets `rows`, so observers re-render in the same pass this value changes.
    var isAtLiveEdge: Bool { window.isAtLiveEdge }
    let updates = PassthroughSubject<TimelineHostUpdate, Never>()

    private let source: any TimelineMessageSource
    private let messageStore: ConversationMessageStore
    private let builder: TimelineRowsBuilder
    private var window = TimelineWindow()
    private var storeRevision: AnyCancellable?
    private var generation = 0
    private var lastViewport = TimelineViewport.empty
    private var lastInitialPosition: TimelineInitialPosition = .liveEdge
    private var olderTask: Task<Void, Never>?
    private var newerTask: Task<Void, Never>?

    init(
        chatID: String,
        currentUserID: Int32,
        isGroupChat: Bool,
        source: any TimelineMessageSource,
        messageStore: ConversationMessageStore,
        threadID: String? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.chatID = chatID
        self.threadID = threadID
        self.source = source
        self.messageStore = messageStore
        builder = TimelineRowsBuilder(currentUserID: currentUserID, isGroupChat: isGroupChat, calendar: calendar)
        storeRevision = messageStore.$revision.dropFirst().sink { [weak self] _ in self?.storeDidChange() }
    }

    // MARK: Initial load

    func loadInitial(position: TimelineInitialPosition = .liveEdge) async {
        guard state.content == .idle || state.content == .initialLoadFailed else { return }
        lastInitialPosition = position
        state.content = .loadingInitial
        let requestGeneration = bumpGeneration()
        let query: ListMessagesQuery
        switch position {
        case .liveEdge: query = liveEdgeQuery
        case .message(let id): query = aroundQuery(id)
        }

        do {
            let page = try await source.fetchMessages(chatID: chatID, query: query)
            guard generation == requestGeneration else { return }
            installWindow(page)
            state.content = .ready
            switch position {
            case .liveEdge:
                settleAtLiveEdge()
                publish(scroll: .bottom(animated: false), reset: true)
            case .message(let id):
                if let rowID = rowID(forServerID: id) {
                    publish(scroll: .reveal(rowID, animated: false, highlight: true), reset: true)
                } else {
                    state.repositionFailure = .message(id)
                    publish(scroll: .bottom(animated: false), reset: true)
                }
            }
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            state.content = .idle
        } catch {
            guard generation == requestGeneration else { return }
            state.content = .initialLoadFailed
        }
    }

    func retryInitial() async { await loadInitial(position: lastInitialPosition) }

    // MARK: Viewport

    func viewportDidChange(_ viewport: TimelineViewport) {
        lastViewport = viewport
        state.live.isPinnedToBottom = viewport.distanceToBottom <= Self.pinnedToBottomTolerance
        if state.live.isPinnedToBottom && isAtLiveEdge {
            state.live.unseenCount = 0
        }
        guard state.content == .ready else { return }
        let threshold = Self.edgePrefetchScreens * viewport.height
        if viewport.distanceToTop < threshold { loadEdge(.older) }
        if viewport.distanceToBottom < threshold { loadEdge(.newer) }
    }

    // MARK: Live edge

    func jumpToLiveEdge() async {
        state.repositionFailure = nil
        if window.isAtLiveEdge {
            settleAtLiveEdge()
            publish(scroll: .bottom(animated: true), reset: false)
            return
        }

        cancelEdgeLoads()
        state.content = .repositioning(.liveEdge)
        let requestGeneration = bumpGeneration()
        do {
            let page = try await source.fetchMessages(chatID: chatID, query: liveEdgeQuery)
            guard generation == requestGeneration else { return }
            installWindow(page)
            state.content = .ready
            settleAtLiveEdge()
            publish(scroll: .bottom(animated: false), reset: true)
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            state.content = .ready
        } catch {
            guard generation == requestGeneration else { return }
            state.content = .ready
            state.repositionFailure = .liveEdge
        }
    }

    func dismissRepositionFailure() {
        state.repositionFailure = nil
    }

    // MARK: Messages

    func enqueue(_ pending: PendingOutgoingMessage) {
        writingStore { messageStore.enqueue(pending) }
        settleAtLiveEdge()
        publish(scroll: .bottom(animated: true), reset: false)
    }

    func receiveLive(_ message: MessageResponse) {
        writingStore { messageStore.receiveLive(message) }
        switch window.insertLive(message) {
        case .deferred:
            state.live.unseenCount += 1
        case .updated:
            publish(scroll: .preserveAnchor, reset: false)
        case .appended:
            if state.live.isPinnedToBottom {
                publish(scroll: .bottom(animated: true), reset: false)
            } else {
                state.live.unseenCount += 1
                publish(scroll: .preserveAnchor, reset: false)
            }
        }
    }

    // MARK: Edge paging

    enum EdgeSide { case older, newer }

    func retryOlder() {
        state.older = .idle
        loadEdge(.older)
    }

    func retryNewer() {
        state.newer = .idle
        loadEdge(.newer)
    }

    private func loadEdge(_ side: EdgeSide) {
        guard state.content == .ready, edge(side) == .idle else { return }
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
                let page = try await source.fetchMessages(chatID: chatID, query: query)
                guard generation == requestGeneration else { return }
                switch side {
                case .older: window.prependOlder(page)
                case .newer: window.appendNewer(page)
                }
                setEdge(side, .idle)
                publish(scroll: .preserveAnchor, reset: false)
            } catch is CancellationError {
                guard generation == requestGeneration else { return }
                setEdge(side, .idle)
            } catch {
                guard generation == requestGeneration else { return }
                setEdge(side, .failed)
            }
        }
        switch side {
        case .older: olderTask = task
        case .newer: newerTask = task
        }
    }

    private func edge(_ side: EdgeSide) -> ConversationTimelineState.Edge {
        switch side {
        case .older: state.older
        case .newer: state.newer
        }
    }

    private func setEdge(_ side: EdgeSide, _ value: ConversationTimelineState.Edge) {
        switch side {
        case .older: state.older = value
        case .newer: state.newer = value
        }
    }

    private func cancelEdgeLoads() {
        olderTask?.cancel()
        newerTask?.cancel()
        olderTask = nil
        newerTask = nil
        state.older = .idle
        state.newer = .idle
    }

    // MARK: Internals

    private var liveEdgeQuery: ListMessagesQuery { .init(max: Self.pageSize, threadID: threadID) }

    private func aroundQuery(_ id: String) -> ListMessagesQuery {
        .init(around: id, max: Self.pageSize, threadID: threadID)
    }

    private func rowID(forServerID id: String) -> TimelineRowID? {
        window.index(ofServerID: id).map { .message(window.messages[$0].timelineStableKey) }
    }

    /// Every fresh window goes through here. The store outlives this screen, so a deferred
    /// buffer from a prior open may overlap or predate the new range; reconcile it against the
    /// installed window so only arrivals strictly newer than the page survive to be replayed.
    private func installWindow(_ page: ListMessagesResponse) {
        window.replace(with: page)
        guard let newest = window.messages.last else { return }
        writingStore {
            messageStore.reconcileDeferredLive(
                chatID: chatID,
                installedKeys: window.stableKeys,
                newestCreatedAt: newest.createdAt
            )
        }
    }

    private func bumpGeneration() -> Int {
        generation += 1
        return generation
    }

    /// Single owner of the invariant `isPinnedToBottom && isAtLiveEdge ⇒ unseenCount == 0`.
    private func settleAtLiveEdge() {
        state.live.isPinnedToBottom = true
        state.live.unseenCount = 0
    }

    /// The model publishes exactly once per operation it originates; store echoes from
    /// those writes are suppressed so a single message never yields two host updates.
    private var isWritingStore = false

    private func writingStore(_ body: () -> Void) {
        isWritingStore = true
        defer { isWritingStore = false }
        body()
    }

    private func storeDidChange() {
        guard !isWritingStore else { return }
        switch state.content {
        case .ready, .repositioning:
            publish(scroll: state.live.isPinnedToBottom ? .bottom(animated: false) : .preserveAnchor, reset: false)
        case .idle, .loadingInitial, .initialLoadFailed:
            return
        }
    }

    /// Rebuilds rows from the merged projection, emits the host update, and reconciles the
    /// store's deferred-live buffer against what is now rendered — regardless of scroll intent.
    private func publish(scroll: TimelineScrollIntent, reset: Bool) {
        let oldRows = rows
        let projection = messageStore.projection(
            for: chatID,
            remoteMessages: window.messages,
            includeDeferredLive: isAtLiveEdge && state.live.isPinnedToBottom
        )
        rows = builder.build(projection.entries)
        let change: TimelineChange = reset ? .reset : .compute(from: oldRows, to: rows)
        updates.send(.init(rows: rows, change: change, scroll: scroll))
        writingStore {
            messageStore.consumeDeferredLive(chatID: chatID, projectedKeys: Set(rows.compactMap(\.stableMessageKey)))
        }
    }
}
