import ChahuaAPI
import SwiftUI

struct PresencePrivacySettingsView: View {
    @ObservedObject private var store: ChatStore
    @StateObject private var model: PresencePrivacySettingsModel
    @State private var loadRetryTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let grouped: Bool
    private let onFinish: (() -> Void)?

    init(store: ChatStore, grouped: Bool, onFinish: (() -> Void)? = nil) {
        self.store = store
        self.grouped = grouped
        self.onFinish = onFinish
        _model = StateObject(wrappedValue: PresencePrivacySettingsModel(store: store))
    }

    var body: some View {
        Group {
            if grouped {
                Form {
                    Section {
                        settingsRows
                    } header: {
                        Text("Who can see my last seen")
                    } footer: {
                        privacyNote
                    }
                    Section {
                        exceptionsPlaceholder
                    } header: {
                        Text("Exceptions")
                    } footer: {
                        exceptionsNote
                    }
                }
                .formStyle(.grouped)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label("Last Seen & Online", systemImage: "eye")
                            .font(.title2.weight(.semibold))
                        Text("Who can see my last seen")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        settingsCard { settingsRows }
                        privacyNote
                            .foregroundStyle(.secondary)
                        Text("Exceptions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        settingsCard { exceptionsPlaceholder }
                        exceptionsNote
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 620)
                    .padding(32)
                    .frame(maxWidth: .infinity)
                }
                .background(ChahuaTheme.conversationBackground(for: colorScheme))
            }
        }
        .navigationTitle("Last Seen & Online")
        .settingsEditorControls(
            isDirty: model.isDirty, canSave: model.canSave, isSaving: model.isSaving,
            accountID: store.currentUserProfile?.uid, onSave: beginSave, onFinish: finish
        )
        .task(id: store.currentUserProfile?.uid) {
            loadRetryTask?.cancel()
            saveTask?.cancel()
            await model.load()
        }
        .onDisappear {
            saveTask?.cancel()
            loadRetryTask?.cancel()
            loadRetryTask = nil
            model.cancelLoading()
        }
    }

    @ViewBuilder
    private var settingsRows: some View {
        switch model.loadPhase {
        case .idle:
            Button("Retry") { retryLoad() }
        case .loading:
            ProgressView("Loading presence privacy settings…")
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text("Failed to load presence privacy settings.")
                    .foregroundStyle(.secondary)
                Button("Retry") { retryLoad() }
            }
        case .loaded:
            ForEach(PresenceVisibility.allCases, id: \.self) { value in
                Button {
                    model.chooseVisibility(value)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            if model.visibility == value {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(width: 24)
                        Text(title(for: value))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isSaving)
                .accessibilityAddTraits(model.visibility == value ? .isSelected : [])
            }
            if model.saveError != nil {
                HStack {
                    Text("Save failed. Please try again.")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry", action: beginSave)
                        .disabled(!model.canSave)
                }
                .font(.footnote)
            }
        }
    }

    // Form supplies its footer color; only the standalone card layout adds secondary styling.
    private var privacyNote: some View {
        Text(
            "Online status and last seen are visible only when both people allow sharing with each other. Group online counts are not affected."
        )
        .font(.footnote)
    }

    private var exceptionsPlaceholder: some View {
        // TODO: Enable exceptions management when the backend provides its API.
        LabeledContent("Never Share With") {
            Text("Coming soon")
        }
        .foregroundStyle(.secondary)
    }

    private var exceptionsNote: some View {
        Text("Exceptions are not available yet.")
            .font(.footnote)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                colorScheme == .dark ? Color.white.opacity(0.07) : Color.white,
                in: RoundedRectangle(cornerRadius: 18))
    }

    private func retryLoad() {
        loadRetryTask?.cancel()
        loadRetryTask = Task { await model.load() }
    }

    private func beginSave() {
        guard model.canSave else { return }
        let uid = store.currentUserProfile?.uid
        let sessionRevision = store.sessionRevision
        saveTask?.cancel()
        saveTask = Task {
            guard !Task.isCancelled, store.currentUserProfile?.uid == uid,
                store.sessionRevision == sessionRevision
            else { return }
            guard await model.save(), !Task.isCancelled,
                store.currentUserProfile?.uid == uid, store.sessionRevision == sessionRevision
            else { return }
            finish()
        }
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }

    private func title(for value: PresenceVisibility) -> LocalizedStringKey {
        switch value {
        case .everyone: "Everyone"
        case .friends: "Friends"
        case .nobody: "Nobody"
        }
    }

}
