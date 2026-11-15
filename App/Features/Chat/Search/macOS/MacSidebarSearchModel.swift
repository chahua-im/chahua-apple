#if os(macOS)
    import ChahuaAPI
    import Combine
    import Foundation

    /// GET /chats has no title-query parameter. Keep independent server cursors and
    /// filter every fetched page locally; typing never restarts or amplifies requests.
    @MainActor
    final class MacSidebarSearchModel: ObservableObject {
        enum Scope: CaseIterable, Hashable {
            case active, archived

            var isArchived: Bool { self == .archived }
        }

        struct PageState {
            var chats: [ChatListItem] = []
            var nextCursor: String?
            var hasMore = true
            var isLoading = false
            var failed = false
            var seenCursors: Set<String> = []
        }

        @Published var query = ""
        @Published private(set) var pages: [Scope: PageState] = [:]
        @Published private(set) var isAvailable = false

        private let accountID: Int32
        private let store: ChatStore
        private var revision = 0
        private var tasks: [Scope: Task<Void, Never>] = [:]
        private var observations: Set<AnyCancellable> = []

        init(currentUserID: Int32, store: ChatStore) {
            accountID = currentUserID
            self.store = store
        }

        deinit {
            for task in tasks.values { task.cancel() }
        }

        func state(for scope: Scope) -> PageState { pages[scope] ?? PageState() }

        func results(in scope: Scope) -> [ChatListItem] {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return state(for: scope).chats.filter {
                text.isEmpty || $0.chatDisplayName.localizedStandardContains(text)
            }
        }

        func start() {
            guard !isAvailable, store.currentUserProfile?.uid == accountID else { return }
            isAvailable = true
            store.$currentUserProfile.map { $0?.uid }.removeDuplicates()
                .sink { [weak self] uid in
                    guard let self, uid != self.accountID else { return }
                    self.stop()
                }
                .store(in: &observations)
            store.conversationMessages.changes.sink { [weak self] change in
                if case .reset = change { self?.stop() }
            }
            .store(in: &observations)
            for scope in Scope.allCases { loadMore(in: scope) }
        }

        func stop() {
            revision += 1
            isAvailable = false
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
            observations.removeAll()
            pages.removeAll()
        }

        /// One user action requests at most one page for this archive scope, even
        /// when that page has no title matches. A failed scope never blocks the other.
        func loadMore(in scope: Scope) {
            guard isAvailable, store.currentUserProfile?.uid == accountID else { return }
            var page = state(for: scope)
            guard page.hasMore, !page.isLoading else { return }
            page.isLoading = true
            page.failed = false
            pages[scope] = page
            let token = revision
            let cursor = page.nextCursor
            tasks[scope] = Task { [weak self] in
                guard let self else { return }
                do {
                    let response = try await store.forwardDestinationChats(
                        query: .init(limit: 30, after: cursor, archived: scope.isArchived))
                    guard current(token) else { return }
                    var updated = state(for: scope)
                    if let next = response.nextCursor,
                        next == cursor || updated.seenCursors.contains(next)
                    {
                        throw APIError.unexpectedResponse
                    }
                    var known = Set(updated.chats.map(\.id))
                    updated.chats.append(
                        contentsOf: response.chats.filter {
                            $0.archived == scope.isArchived && known.insert($0.id).inserted
                        })
                    if let cursor { updated.seenCursors.insert(cursor) }
                    updated.nextCursor = response.nextCursor
                    updated.hasMore = response.nextCursor != nil
                    updated.isLoading = false
                    pages[scope] = updated
                } catch {
                    guard current(token) else { return }
                    var updated = state(for: scope)
                    updated.isLoading = false
                    updated.failed = true
                    pages[scope] = updated
                }
                if current(token) { tasks[scope] = nil }
            }
        }

        private func current(_ token: Int) -> Bool {
            isAvailable && revision == token && store.currentUserProfile?.uid == accountID
                && !Task.isCancelled
        }
    }
#endif
