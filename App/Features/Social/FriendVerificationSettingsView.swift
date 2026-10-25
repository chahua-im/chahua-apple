import ChahuaAPI
import SwiftUI

/// Permission changes remain local until Save; exits return to the existing Settings hierarchy.
struct FriendVerificationSettingsView: View {
    @ObservedObject var store: ChatStore
    let grouped: Bool
    var onFinish: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: FriendVerificationMode = .direct
    @State private var question = ""
    @State private var originalMode: FriendVerificationMode = .direct
    @State private var originalQuestion = ""
    @State private var loaded = false
    @State private var loading = false
    @State private var saving = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var accountID: Int32?
    @State private var revision = 0
    @State private var retryTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Group {
            if grouped {
                Form {
                    Section("Who can add me") {
                        settingsRows
                    }
                    if loaded && mode == .question {
                        Section {
                            questionField
                        } footer: {
                            questionNote
                        }
                    }
                    if let saveError {
                        Section {
                            saveFailure(saveError)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label(
                            "Friend Request Permission",
                            systemImage: "person.badge.shield.checkmark"
                        )
                        .font(.title2.weight(.semibold))
                        Text("Who can add me")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        settingsCard { settingsRows }
                        if loaded && mode == .question {
                            settingsCard { questionField }
                            questionNote.foregroundStyle(.secondary)
                        }
                        if let saveError {
                            settingsCard { saveFailure(saveError) }
                        }
                    }
                    .frame(maxWidth: 620)
                    .padding(32)
                    .frame(maxWidth: .infinity)
                }
                .background(ChahuaTheme.conversationBackground(for: colorScheme))
            }
        }
        .navigationTitle("Friend Request Permission")
        .settingsEditorControls(
            isDirty: isDirty, canSave: canSave, isSaving: saving,
            accountID: store.currentUserProfile?.uid, onSave: beginSave, onFinish: finish
        )
        .task(id: store.currentUserProfile?.uid) {
            retryTask?.cancel()
            await load()
        }
        .onDisappear {
            revision &+= 1
            retryTask?.cancel()
            saveTask?.cancel()
        }
    }

    @ViewBuilder
    private var settingsRows: some View {
        if loading {
            ProgressView("Loading friend verification…")
        } else if let loadError {
            Text(loadError).foregroundStyle(.red)
            Button("Retry") {
                retryTask?.cancel()
                retryTask = Task { await load() }
            }
        } else if loaded {
            ForEach(FriendVerificationMode.allCases, id: \.self) { choice in
                Button {
                    mode = choice
                    saveError = nil
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            if mode == choice {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(width: 24)
                        Text(title(choice))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == choice ? .isSelected : [])
            }
        }
    }

    private var questionField: some View {
        TextField("Question", text: $question, axis: .vertical)
            .onChange(of: question) { _, _ in saveError = nil }
    }

    private var questionNote: some View {
        Text(
            "Enter a non-empty question, up to 100 characters. Changes are saved only when you choose Save."
        )
        .font(.footnote)
    }

    private func saveFailure(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error).foregroundStyle(.red)
            Button("Retry Save") { beginSave() }
                .disabled(!canSave)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                colorScheme == .dark ? Color.white.opacity(0.07) : Color.white,
                in: RoundedRectangle(cornerRadius: 18))
    }

    private var isDirty: Bool {
        loaded && (mode != originalMode || question != originalQuestion)
    }

    private var canSave: Bool {
        loaded && !loading && !saving && accountID != nil
            && accountID == store.currentUserProfile?.uid
            && (mode != .question || validQuestion)
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }

    private func beginSave() {
        guard canSave, let uid = accountID else { return }
        // Capture the draft and session before scheduling so queued work cannot use another account.
        let settings = FriendVerificationSettings(
            mode: mode,
            question: mode == .question
                ? question.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        let requestRevision = revision
        saving = true
        saveTask = Task { await save(settings, uid: uid, requestRevision: requestRevision) }
    }

    private var validQuestion: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && question.count <= 100
    }

    private func title(_ mode: FriendVerificationMode) -> String {
        switch mode {
        case .direct: AppLanguage.localized("Allow direct requests")
        case .needMessage: AppLanguage.localized("Require a verification message")
        case .question: AppLanguage.localized("Require an answer to a question")
        case .forbid: AppLanguage.localized("Do not allow friend requests")
        }
    }

    private func load() async {
        revision &+= 1
        let requestRevision = revision
        saveTask?.cancel()
        let uid = store.currentUserProfile?.uid
        accountID = uid
        loaded = false
        loading = false
        saving = false
        loadError = nil
        saveError = nil
        guard let uid else { return }
        loading = true
        defer { if revision == requestRevision { loading = false } }
        do {
            let settings = try await store.friendVerificationSettings()
            try Task.checkCancellation()
            guard revision == requestRevision, store.currentUserProfile?.uid == uid else { return }
            mode = settings.mode
            question = settings.question ?? ""
            originalMode = mode
            originalQuestion = question
            loaded = true
        } catch is CancellationError {} catch {
            guard revision == requestRevision, store.currentUserProfile?.uid == uid else { return }
            loadError = error.localizedDescription
        }
    }

    private func save(
        _ draft: FriendVerificationSettings, uid: Int32, requestRevision: Int
    ) async {
        guard revision == requestRevision, loaded, saving,
            store.currentUserProfile?.uid == uid
        else { return }
        saveError = nil
        defer { if revision == requestRevision { saving = false } }
        do {
            try Task.checkCancellation()
            let settings = try await store.updateFriendVerificationSettings(draft)
            try Task.checkCancellation()
            guard revision == requestRevision, store.currentUserProfile?.uid == uid else { return }
            mode = settings.mode
            question = settings.question ?? ""
            originalMode = mode
            originalQuestion = question
            finish()
        } catch is CancellationError {} catch {
            guard revision == requestRevision, store.currentUserProfile?.uid == uid else { return }
            saveError = error.localizedDescription
        }
    }
}
