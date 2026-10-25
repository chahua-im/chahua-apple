import ChahuaAPI
import Combine
import Foundation

/// One settings scope per instance; no policy is assumed until its read succeeds.
@MainActor
final class ReadReceiptPrivacySettingsModel: ObservableObject {
    enum Scope: Equatable {
        case account
        case friend(Int32)
    }

    enum Choice: Hashable {
        case visibility(ReadReceiptVisibility)
        case friendOverride(FriendReadReceiptOverride)
    }

    enum LoadPhase: Equatable {
        case idle, loading, loaded, failed, notFriend
    }

    @Published private(set) var selection: Choice?
    @Published private(set) var loadPhase: LoadPhase = .idle
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?

    let scope: Scope
    private let store: ChatStore
    private var revision = 0
    private var baseline: Choice?
    private var sessionObservation: AnyCancellable?
    private var accountObservation: AnyCancellable?

    var choices: [Choice] {
        switch scope {
        case .account: ReadReceiptVisibility.allCases.map(Choice.visibility)
        case .friend: FriendReadReceiptOverride.allCases.map(Choice.friendOverride)
        }
    }

    var isDirty: Bool {
        scope == .account && loadPhase == .loaded && selection != baseline
    }

    var canSave: Bool {
        scope == .account && loadPhase == .loaded && baseline != nil && !isSaving
            && selection.map { choices.contains($0) } == true
    }

    init(store: ChatStore, scope: Scope = .account) {
        self.store = store
        self.scope = scope
        accountObservation = store.$currentUserProfile
            .map { $0?.uid }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.resetForAccountChange() }
        sessionObservation = store.$sessionRevision.dropFirst()
            .sink { [weak self] _ in self?.resetForAccountChange() }
    }

    func load() async {
        guard !isSaving else { return }
        revision &+= 1
        let requestRevision = revision
        selection = nil
        baseline = nil
        loadPhase = .loading
        saveError = nil
        do {
            let choice: Choice
            switch scope {
            case .account:
                choice = .visibility(try await store.readReceiptSettings().visibility)
            case .friend(let uid):
                let relationship = try await store.friendRelationship(peerUID: uid)
                try Task.checkCancellation()
                guard revision == requestRevision else { return }
                guard relationship.isFriend == true else {
                    loadPhase = .notFriend
                    return
                }
                choice = .friendOverride(
                    try await store.friendReadReceiptSettings(peerUID: uid).override)
            }
            try Task.checkCancellation()
            guard revision == requestRevision else { return }
            selection = choice
            baseline = choice
            loadPhase = .loaded
        } catch {
            guard revision == requestRevision else { return }
            loadPhase = error is CancellationError || Task.isCancelled ? .idle : .failed
        }
    }

    func choose(_ choice: Choice) async {
        guard loadPhase == .loaded, !isSaving, choices.contains(choice),
            selection != choice || saveError != nil
        else { return }
        selection = choice
        saveError = nil
        if case .friend = scope { _ = await persistSelection() }
    }

    func retrySave() async {
        guard case .friend = scope, saveError != nil else { return }
        _ = await persistSelection()
    }

    func save() async -> Bool {
        guard canSave else { return false }
        return await persistSelection()
    }

    private func persistSelection() async -> Bool {
        guard loadPhase == .loaded, !isSaving, !Task.isCancelled, let selection else {
            return false
        }
        revision &+= 1
        let requestRevision = revision
        isSaving = true
        saveError = nil
        defer { if revision == requestRevision { isSaving = false } }
        do {
            let saved: Choice
            switch (scope, selection) {
            case (.account, .visibility(let visibility)):
                saved = .visibility(
                    try await store.updateReadReceiptSettings(visibility: visibility).visibility)
            case (.friend(let uid), .friendOverride(let override)):
                saved = .friendOverride(
                    try await store.updateFriendReadReceiptSettings(
                        peerUID: uid, override: override
                    ).override)
            default:
                return false
            }
            // Store invalidates receipts on commit even if this view was dismissed.
            try Task.checkCancellation()
            guard revision == requestRevision else { return false }
            self.selection = saved
            baseline = saved
            return true
        } catch {
            guard revision == requestRevision else { return false }
            if !(error is CancellationError) && !Task.isCancelled {
                saveError = error.localizedDescription
            }
        }
        return false
    }

    func cancelLoading() {
        guard loadPhase == .loading else { return }
        revision &+= 1
        loadPhase = .idle
    }

    private func resetForAccountChange() {
        revision &+= 1
        selection = nil
        baseline = nil
        loadPhase = .idle
        isSaving = false
        saveError = nil
    }
}
