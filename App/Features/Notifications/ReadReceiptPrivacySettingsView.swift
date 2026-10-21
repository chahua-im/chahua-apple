import ChahuaAPI
import SwiftUI

struct ReadReceiptPrivacySettingsView: View {
    @ObservedObject private var store: ChatStore
    let grouped: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(store: ChatStore, grouped: Bool) {
        self.store = store
        self.grouped = grouped
    }

    var body: some View {
        Group {
            if grouped {
                Form {
                    Section("Who can see my read receipts") {
                        ReadReceiptPrivacySettingsRows(store: store)
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
                        ReadReceiptPrivacySettingsRows(store: store)
                            .padding(20)
                            .background(
                                colorScheme == .dark ? Color.white.opacity(0.07) : Color.white,
                                in: RoundedRectangle(cornerRadius: 18))
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
    }
}

/// Shared automatic-save controls for account settings and the DM friend's override card.
struct ReadReceiptPrivacySettingsRows: View {
    @ObservedObject private var store: ChatStore
    @StateObject private var model: ReadReceiptPrivacySettingsModel
    @State private var loadRetryTask: Task<Void, Never>?

    init(store: ChatStore, peerUID: Int32? = nil) {
        self.store = store
        _model = StateObject(
            wrappedValue: ReadReceiptPrivacySettingsModel(
                store: store, scope: peerUID.map { .friend($0) } ?? .account))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.scope != .account, model.loadPhase != .notFriend {
                Text("Read receipt sharing")
                    .font(.headline)
            }
            settingsRows
            if model.loadPhase != .notFriend {
                Text(
                    "Read receipts are visible only when both people allow sharing. Group conversations never show read receipts."
                )
                .font(.footnote)
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

    @ViewBuilder
    private var settingsRows: some View {
        switch model.loadPhase {
        case .notFriend:
            EmptyView()
        case .idle:
            Button("Retry") { retryLoad() }
        case .loading:
            ProgressView("Loading read receipt settings…")
        case .failed:
            Text(
                model.scope == .account
                    ? LocalizedStringKey("Failed to load read receipt settings.")
                    : LocalizedStringKey("Failed to load this friend's read receipt setting.")
            )
            .foregroundStyle(.secondary)
            Button("Retry") { retryLoad() }
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

    private func retryLoad() {
        loadRetryTask?.cancel()
        loadRetryTask = Task { await model.load() }
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
