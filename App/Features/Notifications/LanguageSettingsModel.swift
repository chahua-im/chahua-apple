import ChahuaAPI
import Combine
import Foundation

/// The preference is app-wide; only an explicit Save writes the local draft.
@MainActor
final class LanguageSettingsModel: ObservableObject {
    @Published private(set) var selection: AppLanguage

    private let defaults: UserDefaults
    private var baseline: AppLanguage
    private var accountObservation: AnyCancellable?
    private var sessionObservation: AnyCancellable?

    init(store: ChatStore, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let persisted =
            AppLanguage(
                rawValue: defaults.string(forKey: AppLanguage.storageKey) ?? "") ?? .system
        selection = persisted
        baseline = persisted
        accountObservation = store.$currentUserProfile
            .map { $0?.uid }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.discardChanges() }
        sessionObservation = store.$sessionRevision.dropFirst()
            .sink { [weak self] _ in self?.discardChanges() }
    }

    var isDirty: Bool { selection != baseline }

    func choose(_ language: AppLanguage) {
        selection = language
    }

    func discardChanges() {
        let persisted =
            AppLanguage(
                rawValue: defaults.string(forKey: AppLanguage.storageKey) ?? "") ?? .system
        baseline = persisted
        selection = persisted
    }

    /// UserDefaults commits synchronously: there is no pending request to cancel or fake spinner.
    @discardableResult
    func save() -> Bool {
        guard isDirty else { return false }
        defaults.set(selection.rawValue, forKey: AppLanguage.storageKey)
        baseline = selection
        return true
    }
}
