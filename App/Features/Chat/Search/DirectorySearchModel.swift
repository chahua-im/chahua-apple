import ChahuaAPI
import Combine
import Foundation

/// The directory's independent server searches. A failed section never discards another section.
@MainActor
final class DirectorySearchModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded, failed
    }

    @Published private(set) var people: [MemberSummary] = []
    @Published private(set) var groups: [SocialGroupSummary] = []
    @Published private(set) var invite: GroupInvitePreview?
    @Published private(set) var peoplePhase: Phase = .idle
    @Published private(set) var groupsPhase: Phase = .idle
    @Published private(set) var invitePhase: Phase = .idle
    @Published private(set) var nextGroupCursor: String?
    @Published private(set) var isAvailable = false
    @Published private(set) var openingGroupID: String?
    @Published private(set) var openingError: String?

    let store: ChatStore
    private let accountID: Int32
    private let sessionRevision: Int
    private let includesGroups: Bool
    private let includesInvites: Bool
    private(set) var term = ""
    private(set) var inviteCode: String?
    private var revision = 0
    private var seenGroupCursors = Set<String>()
    private var debounceTask: Task<Void, Never>?
    private var peopleTask: Task<Void, Never>?
    private var groupsTask: Task<Void, Never>?
    private var inviteTask: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()

    init(
        currentUserID: Int32, store: ChatStore, includesGroups: Bool = true,
        includesInvites: Bool = true
    ) {
        accountID = currentUserID
        self.store = store
        sessionRevision = store.sessionRevision
        self.includesGroups = includesGroups
        self.includesInvites = includesInvites
    }

    deinit {
        debounceTask?.cancel()
        peopleTask?.cancel()
        groupsTask?.cancel()
        inviteTask?.cancel()
    }

    var isSettled: Bool {
        peoplePhase == .loaded && groupsPhase != .loading && groupsPhase != .failed
            && invitePhase != .loading && invitePhase != .failed
    }

    func start() {
        guard !isAvailable, authorized else { return }
        isAvailable = true
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
        search(term, force: true)
    }

    func stop() {
        revision &+= 1
        isAvailable = false
        cancelRequests()
        observations.removeAll()
        clearResults()
    }

    func search(_ query: String, force: Bool = false) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard force || value != term else { return }
        term = value
        revision &+= 1
        cancelRequests()
        clearResults()
        guard isAvailable, authorized, !value.isEmpty else { return }
        inviteCode = includesInvites ? Self.inviteCode(in: value) : nil
        peoplePhase = .loading
        groupsPhase = includesGroups ? .loading : .idle
        invitePhase = inviteCode != nil ? .loading : .idle
        let token = revision
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, current(token) else { return }
            loadPeople()
            if includesGroups { loadGroups() }
            if inviteCode != nil { loadInvite() }
            debounceTask = nil
        }
    }

    func retryPeople() {
        guard peoplePhase == .failed else { return }
        loadPeople()
    }

    func retryGroups() {
        guard groupsPhase == .failed else { return }
        loadGroups()
    }

    func loadMoreGroups() {
        guard groupsPhase == .loaded, nextGroupCursor != nil else { return }
        loadGroups()
    }

    func retryInvite() {
        guard invitePhase == .failed else { return }
        loadInvite()
    }

    func canOpenPerson(_ uid: Int32) -> Bool {
        current(revision) && people.contains { $0.uid == uid }
    }

    func canOpenInvite(_ code: String) -> Bool {
        current(revision) && invite != nil && inviteCode == code
    }

    func openGroup(_ id: String) async -> ChatListItem? {
        guard current(revision), openingGroupID == nil, groups.contains(where: { $0.id == id })
        else { return nil }
        let token = revision
        openingGroupID = id
        openingError = nil
        defer { if current(token) { openingGroupID = nil } }
        do {
            let chat = try await store.socialChat(id: id)
            guard current(token) else { return nil }
            return chat
        } catch {
            guard current(token) else { return nil }
            openingError = error.localizedDescription
            return nil
        }
    }

    private var authorized: Bool {
        store.currentUserProfile?.uid == accountID && store.sessionRevision == sessionRevision
    }

    private func current(_ token: Int) -> Bool {
        isAvailable && authorized && revision == token && !Task.isCancelled
    }

    private func cancelRequests() {
        debounceTask?.cancel()
        peopleTask?.cancel()
        groupsTask?.cancel()
        inviteTask?.cancel()
        debounceTask = nil
        peopleTask = nil
        groupsTask = nil
        inviteTask = nil
    }

    private func clearResults() {
        people = []
        groups = []
        invite = nil
        inviteCode = nil
        peoplePhase = .idle
        groupsPhase = .idle
        invitePhase = .idle
        nextGroupCursor = nil
        seenGroupCursors.removeAll()
        openingGroupID = nil
        openingError = nil
    }

    private func loadPeople() {
        guard current(revision), !term.isEmpty, peopleTask == nil else { return }
        peoplePhase = .loading
        let token = revision
        let query = term
        peopleTask = Task { [weak self] in
            guard let self else { return }
            defer { if current(token) { peopleTask = nil } }
            do {
                let response = try await store.searchUsers(query: query)
                guard current(token) else { return }
                var known = Set<Int32>()
                people = response.members.filter { known.insert($0.uid).inserted }
                peoplePhase = .loaded
            } catch {
                guard current(token) else { return }
                peoplePhase = .failed
            }
        }
    }

    private func loadGroups() {
        guard current(revision), includesGroups, !term.isEmpty, groupsTask == nil else { return }
        groupsPhase = .loading
        let token = revision
        let query = term
        let cursor = nextGroupCursor
        groupsTask = Task { [weak self] in
            guard let self else { return }
            defer { if current(token) { groupsTask = nil } }
            do {
                let response = try await store.searchJoinedGroups(query: query, after: cursor)
                guard current(token) else { return }
                if let next = response.nextCursor,
                    next == cursor || seenGroupCursors.contains(next)
                {
                    throw APIError.unexpectedResponse
                }
                var known = Set(groups.map(\.id))
                groups.append(contentsOf: response.groups.filter { known.insert($0.id).inserted })
                if let cursor { seenGroupCursors.insert(cursor) }
                nextGroupCursor = response.nextCursor
                groupsPhase = .loaded
            } catch {
                guard current(token) else { return }
                groupsPhase = .failed
            }
        }
    }

    private func loadInvite() {
        guard current(revision), let code = inviteCode, inviteTask == nil else { return }
        invitePhase = .loading
        let token = revision
        inviteTask = Task { [weak self] in
            guard let self else { return }
            defer { if current(token) { inviteTask = nil } }
            do {
                let response = try await store.previewGroupInvite(code: code)
                guard current(token) else { return }
                invite = response
                invitePhase = .loaded
            } catch {
                guard current(token) else { return }
                invitePhase = .failed
            }
        }
    }

    private static func inviteCode(in value: String) -> String? {
        guard let code = GroupInviteLink.code(from: value) else { return nil }
        // Links have an explicit invite route; bare usernames only resemble codes at 8–12 characters.
        return code != value || (8...12).contains(code.count) ? code : nil
    }
}
