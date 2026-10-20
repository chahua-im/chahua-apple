import ChahuaAPI
import Combine
import Foundation

/// Server-backed choices save on selection; no policy is assumed before a successful read.
@MainActor
final class PresencePrivacySettingsModel: ObservableObject {
    enum LoadPhase: Equatable {
        case idle, loading, loaded, failed
    }

    @Published private(set) var visibility: PresenceVisibility?
    @Published private(set) var loadPhase: LoadPhase = .idle
    @Published private(set) var isSaving = false
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?

    private let store: ChatStore
    private var revision = 0
    private var accountObservation: AnyCancellable?

    init(store: ChatStore) {
        self.store = store
        accountObservation = store.$currentUserProfile
            .map { $0?.uid }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.resetForAccountChange() }
    }

    /// Reopening during a save keeps its selection visible until the write completes.
    func load() async {
        guard !isSaving else { return }
        revision &+= 1
        let requestRevision = revision
        visibility = nil
        loadPhase = .loading
        loadError = nil
        saveError = nil

        do {
            let response = try await store.presenceSettings()
            try Task.checkCancellation()
            guard revision == requestRevision else { return }
            visibility = response.visibility
            loadPhase = .loaded
        } catch {
            guard revision == requestRevision else { return }
            if error is CancellationError || Task.isCancelled {
                loadPhase = .idle
            } else {
                loadError = error.localizedDescription
                loadPhase = .failed
            }
        }
    }

    func chooseVisibility(_ value: PresenceVisibility) async {
        guard loadPhase == .loaded, !isSaving, visibility != value || saveError != nil else {
            return
        }
        visibility = value
        await persistSelection()
    }

    func retrySave() async {
        guard saveError != nil else { return }
        await persistSelection()
    }

    private func persistSelection() async {
        guard loadPhase == .loaded, !isSaving, let visibility else { return }
        revision &+= 1
        let requestRevision = revision
        isSaving = true
        saveError = nil
        defer {
            if revision == requestRevision { isSaving = false }
        }

        do {
            // ChatStore owns auth fencing and presence invalidation on committed writes.
            let response = try await store.updatePresenceSettings(visibility: visibility)
            try Task.checkCancellation()
            guard revision == requestRevision else { return }
            self.visibility = response.visibility
        } catch {
            guard revision == requestRevision else { return }
            if !(error is CancellationError) && !Task.isCancelled {
                // Keep the selected draft so retry sends exactly what the user chose.
                saveError = error.localizedDescription
            }
        }
    }

    /// Dismissing a page cancels reads, not an automatic save already in progress.
    func cancelLoading() {
        guard loadPhase == .loading else { return }
        revision &+= 1
        loadPhase = .idle
    }

    private func resetForAccountChange() {
        revision &+= 1
        isSaving = false
        visibility = nil
        loadPhase = .idle
        loadError = nil
        saveError = nil
    }
}
