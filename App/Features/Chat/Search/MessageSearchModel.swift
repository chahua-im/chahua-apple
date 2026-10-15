import ChahuaAPI
import Combine
import Foundation

/// Chat-scoped message search state.
///
/// The shell retains one model per selected chat so dismissing the search sheet
/// to read a result and reopening it restores the query, ordering, and loaded pages.
@MainActor
final class MessageSearchModel: ObservableObject {
    enum Phase: Equatable {
        /// No query text.
        case idle
        /// Query text is shorter than the server minimum.
        case tooShort
        case loading
        case loaded
        case failed(Failure)
    }

    enum Failure: Equatable {
        /// The server has no message search configured or its index is unreachable (HTTP 503).
        case unavailable
        case other
    }

    typealias Search = @MainActor (SearchMessagesQuery) async throws -> SearchMessagesResponse

    /// Matches the server's normalized minimum, counted in Unicode scalars.
    static let minimumQueryLength = 2
    static let pageSize = 20

    let chatID: String

    /// Raw field text. Edits search after the debounce interval; see `submit()`.
    @Published var queryText = "" {
        didSet {
            guard queryText != oldValue else { return }
            startSearch(debounce: true, force: false)
        }
    }
    @Published var sort: MessageSearchSort = .relevance {
        didSet {
            guard sort != oldValue else { return }
            startSearch(debounce: false, force: false)
        }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [MessageResponse] = []
    @Published private(set) var nextOffset: Int?
    @Published private(set) var isLoadingMore = false
    @Published private(set) var loadMoreFailed = false

    private let search: Search
    private let debounce: Duration
    /// Normalized text and ordering that own `results`, or the in-flight first page.
    private var activeRequest: (q: String, sort: MessageSearchSort)?
    private var revision = 0
    private var firstPageTask: Task<Void, Never>?
    private var nextPageTask: Task<Void, Never>?

    init(chatID: String, debounce: Duration = .milliseconds(300), search: @escaping Search) {
        self.chatID = chatID
        self.debounce = debounce
        self.search = search
    }

    deinit {
        firstPageTask?.cancel()
        nextPageTask?.cancel()
    }

    /// Searches the current text immediately, including repeating a loaded search.
    func submit() {
        startSearch(debounce: false, force: true)
    }

    /// Repeats the first page after a failure.
    func retry() {
        startSearch(debounce: false, force: true)
    }

    func loadMore() {
        guard phase == .loaded, !isLoadingMore, let offset = nextOffset,
            let request = activeRequest
        else { return }
        let requestRevision = revision
        isLoadingMore = true
        loadMoreFailed = false
        nextPageTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.revision == requestRevision {
                    self.isLoadingMore = false
                    self.nextPageTask = nil
                }
            }
            do {
                let response = try await self.search(
                    SearchMessagesQuery(
                        q: request.q, sort: request.sort, limit: Self.pageSize, offset: offset))
                try Task.checkCancellation()
                guard self.revision == requestRevision else { return }
                self.results = Self.merging(self.results, with: response.messages)
                // A non-advancing offset would repeat the same page indefinitely.
                self.nextOffset = response.nextOffset.flatMap { $0 > offset ? $0 : nil }
            } catch is CancellationError {
                // A newer search owns state.
            } catch {
                guard self.revision == requestRevision else { return }
                self.loadMoreFailed = true
            }
        }
    }

    private func startSearch(debounce: Bool, force: Bool) {
        let q = Self.normalized(queryText)
        if !force, phase != .tooShort, phase != .idle, !isFailed,
            let activeRequest, activeRequest.q == q, activeRequest.sort == sort
        {
            return
        }

        revision &+= 1
        firstPageTask?.cancel()
        nextPageTask?.cancel()
        firstPageTask = nil
        nextPageTask = nil
        isLoadingMore = false
        loadMoreFailed = false
        results = []
        nextOffset = nil

        guard q.unicodeScalars.count >= Self.minimumQueryLength else {
            activeRequest = nil
            phase = q.isEmpty ? .idle : .tooShort
            return
        }

        let request = (q: q, sort: sort)
        let requestRevision = revision
        activeRequest = request
        phase = .loading
        let delay = debounce ? self.debounce : .zero
        firstPageTask = Task { [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                guard let self else { return }
                let response = try await self.search(
                    SearchMessagesQuery(q: request.q, sort: request.sort, limit: Self.pageSize))
                try Task.checkCancellation()
                guard self.revision == requestRevision else { return }
                self.results = Self.merging([], with: response.messages)
                self.nextOffset = response.nextOffset.flatMap { $0 > 0 ? $0 : nil }
                self.phase = .loaded
                self.firstPageTask = nil
            } catch is CancellationError {
                // A newer search or dismissal owns state.
            } catch {
                guard let self, self.revision == requestRevision else { return }
                self.phase = .failed(Self.failure(for: error))
                self.firstPageTask = nil
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Mirrors the server's query normalization closely enough for the length gate.
    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func failure(for error: Error) -> Failure {
        switch error {
        case APIError.http(status: 503, _), APIError.unavailable: .unavailable
        default: .other
        }
    }

    /// Offset pages can overlap when matching messages arrive between requests.
    private static func merging(_ existing: [MessageResponse], with incoming: [MessageResponse])
        -> [MessageResponse]
    {
        var seen = Set(existing.map(\.id))
        return existing + incoming.filter { seen.insert($0.id).inserted }
    }
}
