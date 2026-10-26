import ChahuaAPI
import SwiftUI

struct LanguageSettingsView: View {
    @ObservedObject private var store: ChatStore
    @StateObject private var model: LanguageSettingsModel
    @Environment(\.dismiss) private var dismiss
    private let onFinish: (() -> Void)?

    init(store: ChatStore, onFinish: (() -> Void)? = nil) {
        self.store = store
        self.onFinish = onFinish
        _model = StateObject(wrappedValue: LanguageSettingsModel(store: store))
    }

    var body: some View {
        Form {
            Section {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        model.choose(language)
                    } label: {
                        HStack(spacing: 12) {
                            Text(verbatim: language.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if model.selection == language {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.selection == language ? .isSelected : [])
                }
            } header: {
                Text("App language")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Language")
        .settingsEditorControls(
            isDirty: model.isDirty, canSave: model.isDirty, isSaving: false,
            accountID: store.currentUserProfile?.uid, onSave: save, onFinish: finish
        )
        .onDisappear { model.discardChanges() }
    }

    private func save() {
        guard model.save() else { return }
        finish()
    }

    private func finish() {
        model.discardChanges()
        if let onFinish { onFinish() } else { dismiss() }
    }
}
