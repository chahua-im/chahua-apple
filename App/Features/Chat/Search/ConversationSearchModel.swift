import ChahuaAPI
import Combine
import Foundation

/// Reuses loaded conversations immediately, then pages each archive scope without restarting on typing.
@MainActor
final class ConversationSearchModel: ObservableObject {
    enum ResultID: Hashable {
        case invite(String)
        case chat(String)
        case group(String)
        case person(Int32)
    }

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
        var seenCursors = Set<String>()
    }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            directory.search(query)
            hasMovedSelection = false
            selection = resultIDs.first
        }
    }
    @Published private(set) var pages: [Scope: PageState] = [:]
    @Published private(set) var isAvailable = false
    @Published private(set) var selection: ResultID?
    private var hasMovedSelection = false

    let directory: DirectorySearchModel
    let store: ChatStore
    private let accountID: Int32
    private let sessionRevision: Int
    private var revision = 0
    private var tasks: [Scope: Task<Void, Never>] = [:]
    private var observations = Set<AnyCancellable>()
    private var directoryObservation: AnyCancellable?

    init(currentUserID: Int32, store: ChatStore) {
        accountID = currentUserID
        self.store = store
        sessionRevision = store.sessionRevision
        directory = DirectorySearchModel(currentUserID: currentUserID, store: store)
        directoryObservation = directory.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var resultIDs: [ResultID] {
        guard !normalizedQuery.isEmpty else { return [] }
        var result: [ResultID] = []
        if directory.invite != nil, let code = directory.inviteCode {
            result.append(.invite(code))
        }
        result += chats.map { .chat($0.id) }
        result += groups.map { .group($0.id) }
        result += directory.people.map { .person($0.uid) }
        return result
    }

    func reconcileSelection() {
        let ids = resultIDs
        if !hasMovedSelection || selection == nil || !ids.contains(selection!) {
            selection = ids.first
        }
    }

    func moveSelection(by delta: Int) {
        hasMovedSelection = true
        let ids = resultIDs
        guard !ids.isEmpty else { return }
        guard let selection, let index = ids.firstIndex(of: selection) else {
            self.selection = ids.first
            return
        }
        self.selection = ids[min(max(index + delta, 0), ids.count - 1)]
    }

    func open(
        _ result: ResultID? = nil,
        onOpenChat: @escaping (ChatListItem) -> Void,
        onOpenProfile: (Int32) -> Void,
        onOpenInvite: (String) -> Void
    ) {
        guard isAvailable, let result = result ?? selection ?? resultIDs.first else { return }
        selection = result
        hasMovedSelection = true
        switch result {
        case .invite(let code):
            guard directory.canOpenInvite(code) else { return }
            onOpenInvite(code)
        case .person(let uid):
            guard directory.canOpenPerson(uid) else { return }
            onOpenProfile(uid)
        case .chat(let id):
            guard let chat = chats.first(where: { $0.id == id }), canOpen(chat) else { return }
            onOpenChat(chat)
        case .group(let id):
            Task {
                if let chat = await directory.openGroup(id) { onOpenChat(chat) }
            }
        }
    }

    var chats: [ChatListItem] { results(in: .active) + results(in: .archived) }

    var groups: [SocialGroupSummary] {
        let localIDs = Set(chats.map(\.id))
        return directory.groups.filter { !localIDs.contains($0.id) }
    }

    var isEmpty: Bool {
        !normalizedQuery.isEmpty && chats.isEmpty && groups.isEmpty && directory.people.isEmpty
            && directory.invite == nil && directory.isSettled
            && Scope.allCases.allSatisfy {
                let page = state(for: $0)
                return !page.isLoading && !page.failed && !page.hasMore
            }
    }

    func state(for scope: Scope) -> PageState { pages[scope] ?? PageState() }

    func results(in scope: Scope) -> [ChatListItem] {
        guard isAvailable else { return [] }
        let text = normalizedQuery
        return state(for: scope).chats.filter {
            text.isEmpty || $0.chatDisplayName.localizedStandardContains(text)
        }
    }

    func canOpen(_ chat: ChatListItem) -> Bool {
        current(revision) && chats.contains { $0.id == chat.id }
    }

    func start() {
        guard !isAvailable, authorized else { return }
        isAvailable = true
        mergeLoadedChats(store.state)
        store.$currentUserProfile.map { $0?.uid }.removeDuplicates()
            .sink { [weak self] uid in
                guard let self, uid != accountID else { return }
                stop()
            }
            .store(in: &observations)
        store.$sessionRevision.removeDuplicates()
            .sink { [weak self] value in
                guard let self, value != sessionRevision else { return }
                stop()
            }
            .store(in: &observations)
        store.$state.removeDuplicates { previous, next in
            previous.chats == next.chats && previous.archivedChats == next.archivedChats
                && previous.listAvailability[.activeChats] == next.listAvailability[.activeChats]
                && previous.listAvailability[.archivedChats]
                    == next.listAvailability[.archivedChats]
        }
        .dropFirst()
        .sink { [weak self] state in
            guard let self, isAvailable, authorized else { return }
            mergeLoadedChats(state)
        }
        .store(in: &observations)
        directory.search(query)
        directory.start()
        for scope in Scope.allCases { loadMore(in: scope) }
    }

    func stop() {
        revision &+= 1
        isAvailable = false
        selection = nil
        hasMovedSelection = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        observations.removeAll()
        pages.removeAll()
        directory.stop()
    }

    /// At most one page per action, even when a page has no title matches or only contains DMs.
    func loadMore(in scope: Scope) {
        guard current(revision) else { return }
        var page = state(for: scope)
        guard page.hasMore, !page.isLoading else { return }
        page.isLoading = true
        page.failed = false
        pages[scope] = page
        let token = revision
        let cursor = page.nextCursor
        tasks[scope] = Task { [weak self] in
            guard let self else { return }
            defer { if current(token) { tasks[scope] = nil } }
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
        }
    }

    private var authorized: Bool {
        store.currentUserProfile?.uid == accountID && store.sessionRevision == sessionRevision
    }

    private func current(_ token: Int) -> Bool {
        isAvailable && authorized && revision == token && !Task.isCancelled
    }

    private func mergeLoadedChats(_ state: ChatState) {
        for scope in Scope.allCases {
            let loaded = scope.isArchived ? state.archivedChats : state.chats
            var page = self.state(for: scope)
            var known = Set(loaded.map(\.id))
            let moved = Set((scope.isArchived ? state.chats : state.archivedChats).map(\.id))
            // Store snapshots win over older pages, including chats moved between archive scopes.
            page.chats =
                loaded
                + page.chats.filter {
                    !moved.contains($0.id) && known.insert($0.id).inserted
                }
            let listScope: CachedListScope = scope.isArchived ? .archivedChats : .activeChats
            if state.listAvailability[listScope]?.isComplete == true {
                page.hasMore = false
            }
            pages[scope] = page
        }
    }
}
