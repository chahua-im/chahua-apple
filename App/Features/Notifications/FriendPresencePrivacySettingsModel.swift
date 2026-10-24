import ChahuaAPI
import Combine
import Foundation

/// The endpoint authorizes friendship; no policy is assumed before its read succeeds.
@MainActor
final class FriendPresencePrivacySettingsModel: ObservableObject {
    enum LoadPhase: Equatable {
        case idle, loading, loaded, failed
    }

    @Published private(set) var selection: FriendPresenceOverride?
    @Published private(set) var loadPhase: LoadPhase = .idle
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?

    private let store: ChatStore
    private let peerUID: Int32
    private var revision = 0
    private var accountObservation: AnyCancellable?

    init(store: ChatStore, peerUID: Int32) {
        self.store = store
        self.peerUID = peerUID
        accountObservation = store.$currentUserProfile
            .map { $0?.uid }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.resetForAccountChange() }
    }

    func load() async {
        guard !isSaving else { return }
        revision &+= 1
        let requestRevision = revision
        selection = nil
        loadPhase = .loading
        saveError = nil
        do {
            let settings = try await store.friendPresenceSettings(peerUID: peerUID)
            try Task.checkCancellation()
            guard revision == requestRevision else { return }
            selection = settings.override
            loadPhase = .loaded
        } catch {
            guard revision == requestRevision else { return }
            loadPhase = error is CancellationError || Task.isCancelled ? .idle : .failed
        }
    }

    func choose(_ value: FriendPresenceOverride) async {
        guard loadPhase == .loaded, !isSaving, selection != value || saveError != nil else {
            return
        }
        selection = value
        await persistSelection()
    }

    func retrySave() async {
        guard saveError != nil else { return }
        await persistSelection()
    }

    private func persistSelection() async {
        guard loadPhase == .loaded, !isSaving, let selection else { return }
        revision &+= 1
        let requestRevision = revision
        isSaving = true
        saveError = nil
        defer { if revision == requestRevision { isSaving = false } }
        do {
            let settings = try await store.updateFriendPresenceSettings(
                peerUID: peerUID, override: selection)
            try Task.checkCancellation()
            guard revision == requestRevision else { return }
            self.selection = settings.override
        } catch {
            guard revision == requestRevision else { return }
            if !(error is CancellationError) && !Task.isCancelled {
                saveError = error.localizedDescription
            }
        }
    }

    func cancelLoading() {
        guard loadPhase == .loading else { return }
        revision &+= 1
        loadPhase = .idle
    }

    private func resetForAccountChange() {
        revision &+= 1
        selection = nil
        loadPhase = .idle
        isSaving = false
        saveError = nil
    }
}
