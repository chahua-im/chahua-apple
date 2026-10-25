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
    private let sessionRevision: Int
    private var observations = Set<AnyCancellable>()
    private var ownRole: GroupRole?
    private var permissionRevision = 0

    init(chatID: String, currentUserID: Int32, store: ChatStore) {
        self.chatID = chatID
        self.currentUserID = currentUserID
        self.store = store
        sessionRevision = store.sessionRevision
        store.$memberSpeakingModesByChatID
            .sink { [weak self] changes in
                self?.applySpeakingChanges(changes[chatID] ?? [:])
            }
            .store(in: &observations)
        store.$sessionRevision
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.cancelPendingRequests()
                self.members = []
                self.canManageMembers = false
                self.nextCursor = nil
            }
            .store(in: &observations)
    }

    deinit {
        firstPageTask?.cancel()
        nextPageTask?.cancel()
    }

    var isInitialLoad: Bool {
        loadPhase == .loading && members.isEmpty
    }

    func canManage(_ member: MemberResponse) -> Bool {
        isCurrentSession && canManageMembers && member.uid != currentUserID
            && members.contains(where: { $0.uid == member.uid })
            && !mutatingMemberIDs.contains(member.uid)
    }

    var isCurrentSession: Bool {
        store.sessionRevision == sessionRevision && store.currentUserProfile?.uid == currentUserID
    }

    func canEditSpeakingMode(_ member: MemberResponse) -> Bool {
        canManage(member) && members.first(where: { $0.uid == member.uid })?.role == .member
    }

    func updateSpeakingMode(of member: MemberResponse, to mode: SpeakingMode) async throws {
        guard canEditSpeakingMode(member) else { throw GroupMembersActionError.notAuthorized }
        try await performMutation(for: member) {
            try await store.updateMemberSpeakingMode(
                chatID: chatID, uid: member.uid, speakingMode: mode)
        } apply: { [weak self] response in
            self?.applySpeakingChanges([response.uid: response])
        }
    }

    func loadIfNeeded() async {
        guard isCurrentSession, loadPhase == .idle else { return }
        await startFirstPage(
            query: query, mode: searchMode, preservingMembers: false, debounce: false
        ).value
    }

    func refresh() async {
        guard isCurrentSession else { return }
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
        guard isCurrentSession, loadPhase == .loaded, nextCursor != nil,
            mutatingMemberIDs.isEmpty
        else { return }
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
                guard self.isCurrentSession, self.queryRevision == revision else { return }
                self.members = self.merging(self.members, with: response.members)
                self.nextCursor = response.nextCursor
                self.canManageMembers = response.canManageMembers
                self.applySpeakingChanges(
                    self.store.memberSpeakingModesByChatID[self.chatID] ?? [:])
                didLoadPage = true
            } catch is CancellationError {
                // A changed search term or a disappeared screen owns cancellation.
            } catch {
                guard self.isCurrentSession, self.queryRevision == revision else { return }
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
        guard isCurrentSession else { return Task {} }
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
                guard self.isCurrentSession, self.queryRevision == revision else { return }
                self.members = self.deduplicated(response.members)
                self.nextCursor = response.nextCursor
                self.canManageMembers = response.canManageMembers
                self.loadPhase = .loaded
                self.applySpeakingChanges(
                    self.store.memberSpeakingModesByChatID[self.chatID] ?? [:])
            } catch is CancellationError {
                // The next request will own state after a new search or dismissal.
            } catch {
                guard self.isCurrentSession, self.queryRevision == revision else { return }
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
            guard isCurrentSession else { throw CancellationError() }
            if queryRevision == revisionAtStart { cancelPendingRequests() }
            apply(result)
            applySpeakingChanges(store.memberSpeakingModesByChatID[chatID] ?? [:])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isCurrentSession else { throw CancellationError() }
            await refreshPermissionsAfterMutationFailure(for: revisionAtStart)
            throw error
        }
    }

    private func refreshPermissionsAfterMutationFailure(for revision: Int) async {
        guard isCurrentSession, queryRevision == revision else { return }
        // A rejected mutation must not discard later pages or the current search.
        canManageMembers = false
        let requestPermissionRevision = permissionRevision
        do {
            let response = try await store.groupMembers(
                chatID: chatID,
                query: .init(q: query.isEmpty ? nil : query, mode: searchMode, limit: 50))
            try Task.checkCancellation()
            guard isCurrentSession, queryRevision == revision,
                self.permissionRevision == requestPermissionRevision
            else { return }
            canManageMembers = response.canManageMembers
            for member in response.members { replace(member) }
            applySpeakingChanges(store.memberSpeakingModesByChatID[chatID] ?? [:])
        } catch {
            // Keep the visible directory and cursor; explicit Refresh can recover permission.
        }
    }

    private func replace(_ member: MemberResponse) {
        guard let index = members.firstIndex(where: { $0.uid == member.uid }) else { return }
        members[index] = member
    }

    private func applySpeakingChanges(_ changes: [Int32: MemberSpeakingModeResponse]) {
        guard isCurrentSession, !changes.isEmpty else { return }
        let nextOwnRole = changes[currentUserID]?.role
        let ownRoleChanged = nextOwnRole != nil && nextOwnRole != ownRole
        if ownRoleChanged {
            ownRole = nextOwnRole
            permissionRevision &+= 1
        }
        if let ownChange = changes[currentUserID], ownChange.role != .admin {
            canManageMembers = false
        }
        var changed = false
        for index in members.indices {
            guard let update = changes[members[index].uid],
                members[index].role != update.role
                    || members[index].speakingMode != update.speakingMode
            else { continue }
            let member = members[index]
            members[index] = .init(
                uid: member.uid, username: member.username, avatarUrl: member.avatarUrl,
                role: update.role, speakingMode: update.speakingMode)
            changed = true
        }
        if changed {
            // Do not let an older page response restore an obsolete role or restriction.
            cancelPendingRequests()
        }
        if ownRoleChanged, nextOwnRole == .admin, loadPhase != .idle {
            let revision = queryRevision
            Task { [weak self] in
                await self?.refreshPermissionsAfterMutationFailure(for: revision)
            }
        }
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
        AppLanguage.localized("You no longer have permission to manage group members.")
    }
}
