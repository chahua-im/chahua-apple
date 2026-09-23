import ChahuaAPI
import Combine
import Foundation

@MainActor
final class GroupMembersModel: ObservableObject {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    @Published private(set) var members: [MemberResponse] = []
    @Published private(set) var canManageMembers = false
    @Published private(set) var nextCursor: Int32?
    @Published private(set) var loadPhase: LoadPhase = .idle
    @Published private(set) var isLoadingMore = false
    @Published private(set) var loadError: String?
    @Published private(set) var loadMoreError: String?
    @Published private(set) var mutatingMemberIDs = Set<Int32>()

    private let chatID: String
    private let currentUserID: Int32
    private let store: ChatStore
    private var query = ""
    private var searchMode = "autocomplete"
    private var queryRevision = 0
    private var firstPageTask: Task<Void, Never>?
    private var nextPageTask: Task<Void, Never>?
    private var loadMoreRequested = false

    init(chatID: String, currentUserID: Int32, store: ChatStore) {
        self.chatID = chatID
        self.currentUserID = currentUserID
        self.store = store
    }

    deinit {
        firstPageTask?.cancel()
        nextPageTask?.cancel()
    }

    var isInitialLoad: Bool {
        loadPhase == .loading && members.isEmpty
    }

    func canManage(_ member: MemberResponse) -> Bool {
        canManageMembers && member.uid != currentUserID && !mutatingMemberIDs.contains(member.uid)
    }

    func loadIfNeeded() async {
        guard loadPhase == .idle else { return }
        await startFirstPage(
            query: query, mode: searchMode, preservingMembers: false, debounce: false
        ).value
    }

    func refresh() async {
        await startFirstPage(
            query: query, mode: searchMode, preservingMembers: !members.isEmpty, debounce: false
        ).value
    }

    func updateSearchQuery(_ value: String) {
        let normalized = normalizedQuery(value)
        guard normalized != query || searchMode != "autocomplete" else { return }
        _ = startFirstPage(
            query: normalized, mode: "autocomplete", preservingMembers: false, debounce: true)
    }

    func submitSearch(_ value: String) {
        let normalized = normalizedQuery(value)
        _ = startFirstPage(
            query: normalized, mode: "submitted", preservingMembers: false, debounce: false)
    }

    func loadMore() {
        guard loadPhase == .loaded, nextCursor != nil, mutatingMemberIDs.isEmpty else { return }
        if isLoadingMore || nextPageTask != nil {
            loadMoreRequested = true
            return
        }
        guard let after = nextCursor else { return }

        let revision = queryRevision
        let requestQuery = query
        let requestMode = searchMode
        isLoadingMore = true
        loadMoreError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            var didLoadPage = false
            defer {
                if self.queryRevision == revision {
                    let shouldContinue = didLoadPage && self.loadMoreRequested
                    self.loadMoreRequested = false
                    self.isLoadingMore = false
                    self.nextPageTask = nil
                    if shouldContinue { self.loadMore() }
                }
            }

            do {
                let response = try await self.store.groupMembers(
                    chatID: self.chatID,
                    query: .init(
                        q: requestQuery.isEmpty ? nil : requestQuery,
                        mode: requestMode,
                        limit: 50,
                        after: after
                    )
                )
                try Task.checkCancellation()
                guard response.nextCursor != after else { throw APIError.unexpectedResponse }
                guard self.queryRevision == revision else { return }
                self.members = self.merging(self.members, with: response.members)
                self.nextCursor = response.nextCursor
                self.canManageMembers = response.canManageMembers
                didLoadPage = true
            } catch is CancellationError {
                // A changed search term or a disappeared screen owns cancellation.
            } catch {
                guard self.queryRevision == revision else { return }
                self.loadMoreRequested = false
                self.loadMoreError = error.localizedDescription
            }
        }
        nextPageTask = task
    }

    func updateRole(of member: MemberResponse, to role: GroupRole) async throws {
        guard canManage(member) else { throw GroupMembersActionError.notAuthorized }
        try await performMutation(for: member) {
            try await store.updateGroupMemberRole(chatID: chatID, uid: member.uid, role: role)
        } apply: { [weak self] updatedMember in
            self?.replace(updatedMember)
        }
    }

    func remove(_ member: MemberResponse) async throws {
        guard canManage(member) else { throw GroupMembersActionError.notAuthorized }
        try await performMutation(for: member) {
            try await store.removeGroupMember(chatID: chatID, uid: member.uid)
        } apply: { [weak self] in
            self?.members.removeAll { $0.uid == member.uid }
        }
    }

    func cancelPendingRequests() {
        firstPageTask?.cancel()
        nextPageTask?.cancel()
        firstPageTask = nil
        nextPageTask = nil
        queryRevision &+= 1
        isLoadingMore = false
        loadMoreRequested = false
        if loadPhase == .loading {
            loadPhase = members.isEmpty ? .idle : .loaded
        }
    }

    private func startFirstPage(
        query nextQuery: String,
        mode nextMode: String,
        preservingMembers: Bool,
        debounce: Bool
    ) -> Task<Void, Never> {
        firstPageTask?.cancel()
        nextPageTask?.cancel()
        firstPageTask = nil
        nextPageTask = nil
        queryRevision &+= 1
        let revision = queryRevision
        query = nextQuery
        searchMode = nextMode
        nextCursor = nil
        isLoadingMore = false
        loadMoreRequested = false
        loadError = nil
        loadMoreError = nil
        if !preservingMembers {
            members = []
            canManageMembers = false
        }
        loadPhase = .loading

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.queryRevision == revision { self.firstPageTask = nil }
            }

            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(250))
                }
                try Task.checkCancellation()
                let response = try await self.store.groupMembers(
                    chatID: self.chatID,
                    query: .init(
                        q: nextQuery.isEmpty ? nil : nextQuery,
                        mode: nextMode,
                        limit: 50
                    )
                )
                try Task.checkCancellation()
                guard self.queryRevision == revision else { return }
                self.members = self.deduplicated(response.members)
                self.nextCursor = response.nextCursor
                self.canManageMembers = response.canManageMembers
                self.loadPhase = .loaded
            } catch is CancellationError {
                // The next request will own state after a new search or dismissal.
            } catch {
                guard self.queryRevision == revision else { return }
                self.loadError = error.localizedDescription
                self.loadPhase = self.members.isEmpty ? .failed : .loaded
            }
        }
        firstPageTask = task
        return task
    }

    private func performMutation<Result>(
        for member: MemberResponse,
        request: () async throws -> Result,
        apply: (Result) -> Void
    ) async throws {
        guard mutatingMemberIDs.insert(member.uid).inserted else { return }
        // Reads begun before a membership change must not restore an old role or
        // reinsert a removed member after the server accepts the mutation.
        cancelPendingRequests()
        let revisionAtStart = queryRevision
        defer { mutatingMemberIDs.remove(member.uid) }

        do {
            let result = try await request()
            try Task.checkCancellation()
            guard queryRevision == revisionAtStart else {
                await refresh()
                return
            }
            cancelPendingRequests()
            apply(result)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await refreshPermissionsAfterMutationFailure(for: revisionAtStart)
            throw error
        }
    }

    private func refreshPermissionsAfterMutationFailure(for revision: Int) async {
        guard queryRevision == revision else { return }
        canManageMembers = false
        await refresh()
    }

    private func replace(_ member: MemberResponse) {
        guard let index = members.firstIndex(where: { $0.uid == member.uid }) else { return }
        members[index] = member
    }

    private func normalizedQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deduplicated(_ candidates: [MemberResponse]) -> [MemberResponse] {
        merging([], with: candidates)
    }

    private func merging(_ existing: [MemberResponse], with incoming: [MemberResponse])
        -> [MemberResponse]
    {
        var knownIDs = Set<Int32>()
        var result: [MemberResponse] = []
        result.reserveCapacity(existing.count + incoming.count)
        for member in existing where knownIDs.insert(member.uid).inserted {
            result.append(member)
        }
        for member in incoming where knownIDs.insert(member.uid).inserted {
            result.append(member)
        }
        return result
    }
}

private enum GroupMembersActionError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        String(localized: "You no longer have permission to manage group members.")
    }
}
