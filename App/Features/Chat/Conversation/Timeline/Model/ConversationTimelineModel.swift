import Combine
import ChahuaAPI
import Foundation

enum TimelinePhase: Equatable {
    case idle
    case loadingInitial
    case failed
    case ready
    case repositioning
}

enum TimelineInitialPosition: Equatable {
    case liveEdge
    case message(String)
}

@MainActor
final class ConversationTimelineModel: ObservableObject {
    static let pageSize: Int64 = 50
    static let nearbyRowDistance = 30
    static let pinnedToBottomTolerance: CGFloat = 24

    let chatID: String
    let threadID: String?
    @Published private(set) var phase: TimelinePhase = .idle
    @Published private(set) var rows: [TimelineRow] = []
    @Published private(set) var isAtLiveEdge = true
    @Published private(set) var isPinnedToBottom = true
    @Published private(set) var unseenLiveMessageCount = 0
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var isLoadingNewer = false
    let updates = PassthroughSubject<TimelineHostUpdate, Never>()

    private let source: any TimelineMessageSource
    private let messageStore: ConversationMessageStore
    private let builder: TimelineRowsBuilder
    private var window = TimelineWindow()
    private var storeRevision: AnyCancellable?
    private var generation = 0
    private var lastViewport = TimelineViewport.empty
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

    func loadInitial(position: TimelineInitialPosition = .liveEdge) async {
        guard phase == .idle || phase == .failed else { return }
        phase = .loadingInitial
        generation += 1
        let requestGeneration = generation
        let query: ListMessagesQuery
        switch position {
        case .liveEdge: query = .init(max: Self.pageSize, threadID: threadID)
        case .message(let id): query = .init(around: id, max: Self.pageSize, threadID: threadID)
        }

        do {
            let page = try await source.fetchMessages(chatID: chatID, query: query)
            guard generation == requestGeneration else { return }
            window.replace(with: page)
            phase = .ready
            let intent: TimelineScrollIntent
            switch position {
            case .liveEdge:
                intent = .bottom(animated: false)
            case .message(let id):
                guard let index = window.index(ofServerID: id) else {
                    publish(scroll: .bottom(animated: false), reset: true)
                    return
                }
                intent = .reveal(.message(window.messages[index].timelineStableKey), animated: false, highlight: true)
            }
            publish(scroll: intent, reset: true)
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            phase = .idle
        } catch {
            guard generation == requestGeneration else { return }
            phase = .failed
        }
    }

    func retryInitial() async { await loadInitial() }

    func viewportDidChange(_ viewport: TimelineViewport) {
        lastViewport = viewport
        isPinnedToBottom = viewport.distanceToBottom <= Self.pinnedToBottomTolerance
        if isPinnedToBottom && isAtLiveEdge {
            unseenLiveMessageCount = 0
            consumeProjectedDeferredLive()
        }
        let threshold = viewport.height * 2
        if viewport.distanceToTop < threshold { loadOlder() }
        if viewport.distanceToBottom < threshold { loadNewer() }
    }

    func jumpToLiveEdge() async {
        if window.isAtLiveEdge {
            isPinnedToBottom = true
            unseenLiveMessageCount = 0
            publish(scroll: .bottom(animated: true), reset: false)
            consumeProjectedDeferredLive()
        } else {
            phase = .repositioning
            generation += 1
            let requestGeneration = generation
            do {
                let page = try await source.fetchMessages(chatID: chatID, query: .init(max: Self.pageSize, threadID: threadID))
                guard generation == requestGeneration else { return }
                window.replace(with: page)
                phase = .ready
                isAtLiveEdge = true
                unseenLiveMessageCount = 0
                publish(scroll: .bottom(animated: false), reset: true)
                consumeProjectedDeferredLive()
            } catch {
                guard generation == requestGeneration else { return }
                phase = .ready
            }
        }
    }

    func enqueue(_ pending: PendingOutgoingMessage) {
        messageStore.enqueue(pending)
        isPinnedToBottom = true
        unseenLiveMessageCount = 0
        publish(scroll: .bottom(animated: true), reset: false)
    }

    func receiveLive(_ message: MessageResponse) {
        messageStore.receiveLive(message)
        if isAtLiveEdge && isPinnedToBottom {
            _ = window.insertLive(message)
            publish(scroll: .bottom(animated: true), reset: false)
            consumeProjectedDeferredLive()
        } else {
            unseenLiveMessageCount += 1
        }
    }

    func loadOlder() {
        guard phase == .ready, window.hasOlder, !isLoadingOlder, let cursor = window.olderCursor else { return }
        isLoadingOlder = true
        olderTask = Task { [weak self] in
            guard let self else { return }
            defer { isLoadingOlder = false }
            do {
                let page = try await source.fetchMessages(chatID: chatID, query: .init(before: cursor, max: Self.pageSize, threadID: threadID))
                guard !Task.isCancelled else { return }
                window.prependOlder(page)
                publish(scroll: .preserveAnchor, reset: false)
            } catch is CancellationError {
            } catch {
                // Edge failures remain non-destructive; retry state is added next.
            }
        }
    }

    func loadNewer() {
        guard phase == .ready, !window.isAtLiveEdge, !isLoadingNewer, let cursor = window.newerCursor else { return }
        isLoadingNewer = true
        newerTask = Task { [weak self] in
            guard let self else { return }
            defer { isLoadingNewer = false }
            do {
                let page = try await source.fetchMessages(chatID: chatID, query: .init(after: cursor, max: Self.pageSize, threadID: threadID))
                guard !Task.isCancelled else { return }
                window.appendNewer(page)
                publish(scroll: .preserveAnchor, reset: false)
            } catch is CancellationError {
            } catch {
                // Edge failures remain non-destructive; retry state is added next.
            }
        }
    }

    private func storeDidChange() {
        guard phase == .ready || phase == .repositioning else { return }
        publish(scroll: isPinnedToBottom ? .bottom(animated: false) : .preserveAnchor, reset: false)
    }

    private func publish(scroll: TimelineScrollIntent, reset: Bool) {
        let oldRows = rows
        let projection = messageStore.projection(
            for: chatID,
            remoteMessages: window.messages,
            includeDeferredLive: isAtLiveEdge && isPinnedToBottom
        )
        rows = builder.build(projection.entries)
        isAtLiveEdge = window.isAtLiveEdge
        let change: TimelineChange = reset ? .reset : .compute(from: oldRows, to: rows)
        updates.send(.init(rows: rows, change: change, scroll: scroll))
    }

    private func consumeProjectedDeferredLive() {
        let projectedKeys = Set(rows.compactMap(\.stableMessageKey))
        messageStore.consumeDeferredLive(chatID: chatID, projectedKeys: projectedKeys)
    }
}
