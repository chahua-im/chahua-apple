import ChahuaAPI
import SwiftUI

struct ReadReceiptPrivacySettingsView: View {
    @ObservedObject private var store: ChatStore
    @StateObject private var model: ReadReceiptPrivacySettingsModel
    @State private var loadRetryTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsUsesSplitLayout) private var usesSplitLayout
    let grouped: Bool
    private let onFinish: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    init(store: ChatStore, grouped: Bool, onFinish: (() -> Void)? = nil) {
        self.store = store
        self.grouped = grouped
        self.onFinish = onFinish
        _model = StateObject(wrappedValue: ReadReceiptPrivacySettingsModel(store: store))
    }

    var body: some View {
        Group {
            if grouped && !usesSplitLayout {
                Form {
                    Section {
                        ReadReceiptPrivacyOptions(
                            model: model, onRetryLoad: retryLoad, onRetrySave: beginSave)
                    } header: {
                        Text("Who can see my read receipts")
                    } footer: {
                        ReadReceiptPrivacyNote()
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
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("Who can see my read receipts")
                            VStack(alignment: .leading, spacing: usesSplitLayout ? 0 : 16) {
                                ReadReceiptPrivacyOptions(
                                    model: model, onRetryLoad: retryLoad, onRetrySave: beginSave,
                                    usesCardRows: usesSplitLayout)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(usesSplitLayout ? 0 : 20)
                            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
                            ReadReceiptPrivacyNote()
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, usesSplitLayout ? 4 : 0)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("Exceptions")
                            exceptionsPlaceholder
                                .frame(
                                    maxWidth: .infinity, minHeight: optionRowHeight,
                                    alignment: .leading
                                )
                                .padding(.horizontal, 14)
                                .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
                            exceptionsNote
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, usesSplitLayout ? 4 : 0)
                        }
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, usesSplitLayout ? 28 : 32)
                    .padding(.top, usesSplitLayout ? 4 : 32)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .background(
                    usesSplitLayout
                        ? (colorScheme == .dark ? Color(white: 0.11) : Color.white)
                        : ChahuaTheme.conversationBackground(for: colorScheme))
            }
        }
        .navigationTitle("Read Receipts")
        .settingsEditorControls(
            title: "Read Receipts",
            isDirty: model.isDirty, canSave: model.canSave, isSaving: model.isSaving,
            accountID: store.currentUserProfile?.uid, onSave: beginSave,
            onRevert: model.revert, onFinish: finish
        )
        .task(id: "\(store.currentUserProfile?.uid ?? 0)-\(store.sessionRevision)") {
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

    private var cardBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color(white: 0.96)
    }

    private var optionRowHeight: CGFloat {
        #if os(macOS)
            40
        #else
            50
        #endif
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private var exceptionsPlaceholder: some View {
        HStack {
            Text("Never Share With")
            Spacer()
            Text("Coming soon")
        }
        .foregroundStyle(.secondary)
    }

    private var exceptionsNote: some View {
        Text("Exceptions are not available yet.")
            .font(.footnote)
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
            if !usesSplitLayout { finish() }
        }
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }
}

/// Friend overrides live on their own grouped page and save automatically on selection.
struct FriendPrivacySettingsView: View {
    @ObservedObject private var store: ChatStore
    @StateObject private var model: ReadReceiptPrivacySettingsModel
    @StateObject private var presenceModel: FriendPresencePrivacySettingsModel
    @State private var loadRetryTask: Task<Void, Never>?
    @State private var presenceLoadRetryTask: Task<Void, Never>?

    init(store: ChatStore, peerUID: Int32) {
        self.store = store
        _model = StateObject(
            wrappedValue: ReadReceiptPrivacySettingsModel(
                store: store, scope: .friend(peerUID)))
        _presenceModel = StateObject(
            wrappedValue: FriendPresencePrivacySettingsModel(store: store, peerUID: peerUID))
    }

    var body: some View {
        Form {
            if model.loadPhase == .notFriend {
                Section {
                    Text("Privacy overrides are only available for friends.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ReadReceiptPrivacyOptions(model: model, onRetryLoad: retryLoad)
                } header: {
                    Text("Read Receipts")
                } footer: {
                    Text(
                        "Read receipts are mutual. If you hide yours from this friend, you won’t be able to see theirs."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Section {
                    presenceOptions
                } header: {
                    Text("Last Seen & Online")
                } footer: {
                    Text(
                        "Last seen and online status are mutual. If you hide yours from this friend, you won’t be able to see their exact last seen or online status."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy Settings")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: store.currentUserProfile?.uid) {
            async let receipts: Void = model.load()
            async let presence: Void = presenceModel.load()
            _ = await (receipts, presence)
        }
        .onDisappear {
            loadRetryTask?.cancel()
            loadRetryTask = nil
            model.cancelLoading()
            presenceLoadRetryTask?.cancel()
            presenceLoadRetryTask = nil
            presenceModel.cancelLoading()
        }
    }

    private func retryLoad() {
        loadRetryTask?.cancel()
        loadRetryTask = Task { await model.load() }
    }

    private func retryPresenceLoad() {
        presenceLoadRetryTask?.cancel()
        presenceLoadRetryTask = Task { await presenceModel.load() }
    }

    @ViewBuilder
    private var presenceOptions: some View {
        switch presenceModel.loadPhase {
        case .idle:
            Button("Retry", action: retryPresenceLoad)
        case .loading:
            ProgressView("Loading last seen settings…")
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text("Failed to load this friend's last seen setting.")
                    .foregroundStyle(.secondary)
                Button("Retry", action: retryPresenceLoad)
            }
        case .loaded:
            ForEach(FriendPresenceOverride.allCases, id: \.self) { value in
                Button {
                    Task { await presenceModel.choose(value) }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            if presenceModel.selection == value {
                                if presenceModel.isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel("Saving…")
                                } else {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .frame(width: 24)
                        Text(presenceTitle(for: value))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(presenceModel.isSaving)
                .accessibilityAddTraits(presenceModel.selection == value ? .isSelected : [])
            }
            if presenceModel.saveError != nil {
                HStack {
                    Text("Save failed. Please try again.")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { Task { await presenceModel.retrySave() } }
                        .disabled(presenceModel.isSaving)
                }
                .font(.footnote)
            }
        }
    }

    private func presenceTitle(for value: FriendPresenceOverride) -> LocalizedStringKey {
        switch value {
        case .inherit: "Use global setting"
        case .share: "Share with this friend"
        case .hide: "Hide from this friend"
        }
    }
}

/// Render-only choices let the account form own each row without attaching load tasks to rows.
private struct ReadReceiptPrivacyOptions: View {
    @ObservedObject var model: ReadReceiptPrivacySettingsModel
    let onRetryLoad: () -> Void
    var onRetrySave: (() -> Void)? = nil
    var usesCardRows = false

    @ViewBuilder
    var body: some View {
        switch model.loadPhase {
        case .notFriend:
            EmptyView()
        case .idle:
            Button("Retry", action: onRetryLoad)
        case .loading:
            ProgressView("Loading read receipt settings…")
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    model.scope == .account
                        ? LocalizedStringKey("Failed to load read receipt settings.")
                        : LocalizedStringKey("Failed to load this friend's read receipt setting.")
                )
                .foregroundStyle(.secondary)
                Button("Retry", action: onRetryLoad)
            }
        case .loaded:
            let choices = model.choices
            ForEach(choices, id: \.self) { choice in
                Button {
                    Task { await model.choose(choice) }
                } label: {
                    HStack(spacing: 12) {
                        choiceIndicator(for: choice)
                        Text(title(for: choice))
                        Spacer()
                    }
                    .font(usesCardRows ? .system(size: optionFontSize) : .body)
                    .padding(.horizontal, usesCardRows ? 14 : 0)
                    .frame(minHeight: usesCardRows ? optionRowHeight : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isSaving)
                .accessibilityAddTraits(model.selection == choice ? .isSelected : [])
                if usesCardRows && choice != choices.last {
                    Divider().padding(.horizontal, 14)
                }
            }
            if model.saveError != nil {
                HStack {
                    Text("Save failed. Please try again.")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry") {
                        if let onRetrySave {
                            onRetrySave()
                        } else {
                            Task { await model.retrySave() }
                        }
                    }
                    .disabled(model.isSaving || (model.scope == .account && !model.canSave))
                }
                .font(.footnote)
            }
        }
    }

    private var optionFontSize: CGFloat {
        #if os(macOS)
            13
        #else
            16
        #endif
    }

    private var optionRowHeight: CGFloat {
        #if os(macOS)
            40
        #else
            50
        #endif
    }

    @ViewBuilder
    private func choiceIndicator(for choice: ReadReceiptPrivacySettingsModel.Choice) -> some View {
        #if os(macOS)
            if usesCardRows {
                // macOS uses radio choices; iPad keeps the touch-sized checkmark rows.
                Image(systemName: model.selection == choice ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(model.selection == choice ? Color.blue : Color.secondary)
                    .accessibilityHidden(true)
            } else {
                checkmark(for: choice)
            }
        #else
            checkmark(for: choice)
        #endif
    }

    private func checkmark(for choice: ReadReceiptPrivacySettingsModel.Choice) -> some View {
        ZStack {
            if model.selection == choice {
                if model.isSaving && model.scope != .account {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving…")
                } else {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: 24)
    }

    private func title(for choice: ReadReceiptPrivacySettingsModel.Choice) -> LocalizedStringKey {
        switch choice {
        case .visibility(.friends): "Friends only"
        case .visibility(.nobody): "Nobody"
        case .friendOverride(.inherit): "Use global setting"
        case .friendOverride(.share): "Share with this friend"
        case .friendOverride(.hide): "Hide from this friend"
        }
    }
}

private struct ReadReceiptPrivacyNote: View {
    var body: some View {
        Text(
            "Read receipts are visible only when both people allow sharing. Group conversations never show read receipts."
        )
        .font(.footnote)
    }
}
