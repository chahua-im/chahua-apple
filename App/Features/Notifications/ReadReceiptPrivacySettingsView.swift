import ChahuaAPI
import SwiftUI

struct ReadReceiptPrivacySettingsView: View {
    @ObservedObject private var store: ChatStore
    @StateObject private var model: ReadReceiptPrivacySettingsModel
    @State private var loadRetryTask: Task<Void, Never>?
    let grouped: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(store: ChatStore, grouped: Bool) {
        self.store = store
        self.grouped = grouped
        _model = StateObject(wrappedValue: ReadReceiptPrivacySettingsModel(store: store))
    }

    var body: some View {
        Group {
            if grouped {
                Form {
                    Section {
                        ReadReceiptPrivacyOptions(model: model, onRetryLoad: retryLoad)
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
                        Label("Read Receipts", systemImage: "checkmark.message")
                            .font(.title2.weight(.semibold))
                        Text("Who can see my read receipts")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 16) {
                            ReadReceiptPrivacyOptions(model: model, onRetryLoad: retryLoad)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(
                            colorScheme == .dark ? Color.white.opacity(0.07) : Color.white,
                            in: RoundedRectangle(cornerRadius: 18))
                        ReadReceiptPrivacyNote()
                            .foregroundStyle(.secondary)
                        Text("Exceptions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        exceptionsPlaceholder
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(
                                colorScheme == .dark ? Color.white.opacity(0.07) : Color.white,
                                in: RoundedRectangle(cornerRadius: 18))
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
        .navigationTitle("Read Receipts")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: store.currentUserProfile?.uid) { await model.load() }
        .onDisappear {
            loadRetryTask?.cancel()
            loadRetryTask = nil
            model.cancelLoading()
        }
    }

    private var exceptionsPlaceholder: some View {
        LabeledContent("Never Share With") {
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
}

/// Automatic-save override card for a DM friend.
struct ReadReceiptPrivacySettingsRows: View {
    @ObservedObject private var store: ChatStore
    @StateObject private var model: ReadReceiptPrivacySettingsModel
    @State private var loadRetryTask: Task<Void, Never>?

    init(store: ChatStore, peerUID: Int32) {
        self.store = store
        _model = StateObject(
            wrappedValue: ReadReceiptPrivacySettingsModel(
                store: store, scope: .friend(peerUID)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.loadPhase != .notFriend {
                Text("Read receipt sharing")
                    .font(.headline)
            }
            ReadReceiptPrivacyOptions(model: model, onRetryLoad: retryLoad)
            if model.loadPhase != .notFriend {
                ReadReceiptPrivacyNote()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: store.currentUserProfile?.uid) { await model.load() }
        .onDisappear {
            loadRetryTask?.cancel()
            loadRetryTask = nil
            model.cancelLoading()
        }
    }

    private func retryLoad() {
        loadRetryTask?.cancel()
        loadRetryTask = Task { await model.load() }
    }
}

/// Render-only choices let the account form own each row without attaching load tasks to rows.
private struct ReadReceiptPrivacyOptions: View {
    @ObservedObject var model: ReadReceiptPrivacySettingsModel
    let onRetryLoad: () -> Void

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
            ForEach(model.choices, id: \.self) { choice in
                Button {
                    Task { await model.choose(choice) }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            if model.selection == choice {
                                if model.isSaving {
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
                        Text(title(for: choice))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isSaving)
                .accessibilityAddTraits(model.selection == choice ? .isSelected : [])
            }
            if model.saveError != nil {
                HStack {
                    Text("Save failed. Please try again.")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { Task { await model.retrySave() } }
                        .disabled(model.isSaving)
                }
                .font(.footnote)
            }
        }
    }

    private func title(for choice: ReadReceiptPrivacySettingsModel.Choice) -> LocalizedStringKey {
        switch choice {
        case .visibility(.friends): "Friends"
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
