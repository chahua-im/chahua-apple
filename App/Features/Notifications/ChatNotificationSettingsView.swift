import ChahuaAPI
import SwiftUI

/// Full notification chooser opened from chat-list actions.
struct ChatNotificationSettingsView: View {
    @ObservedObject var store: ChatStore
    let chat: ChatListItem
    @State private var saving = false
    @State private var failure: String?
    @State private var accountUID: Int32?
    @Environment(\.dismiss) private var dismiss

    init(store: ChatStore, chat: ChatListItem) {
        self.store = store
        self.chat = chat
        _accountUID = State(initialValue: store.currentUserProfile?.uid)
    }

    private var current: ChatListItem {
        store.state.chats.first { $0.id == chat.id }
            ?? store.state.archivedChats.first { $0.id == chat.id }
            ?? store.notificationChatSnapshot(chat)
    }

    var body: some View {
        Group {
            Form {
                Section {
                    choice(
                        "Use account default", mode: .inherit, selected: current.muteOverride == nil
                    )
                    choice(
                        "Always notify", mode: .alwaysUnmuted,
                        selected: current.muteOverride == false)
                    choice(
                        "Always mute", mode: .alwaysMuted, selected: current.muteOverride == true)
                } header: {
                    Text("Notification settings")
                }
                if !current.notificationPermanentlyMuted(defaults: store.state.notificationDefaults)
                {
                    Section("Temporary mute") {
                        choice("Mute for 1 hour", seconds: 3_600)
                        choice("Mute for 8 hours", seconds: 28_800)
                        choice("Mute for 1 day", seconds: 86_400)
                        choice("Mute for 7 days", seconds: 604_800)
                    }
                }
                if current.mutedUntil.map({ $0 > Date() }) != true {
                    Section {
                        Text(
                            LocalizedStringKey(
                                current.notificationMuted(
                                    defaults: store.state.notificationDefaults)
                                    ? "Notifications muted" : "Notifications enabled"))
                    }
                }
                if let failure {
                    Text(verbatim: failure).foregroundStyle(.red)
                    Button("Retry") {
                        Task {
                            do {
                                try await store.loadNotificationDefaults()
                                self.failure = nil
                            } catch is CancellationError {} catch {
                                self.failure = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(saving)
        }
        .navigationTitle("Notification settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
        .task {
            store.trackNotificationExpiry(for: current)
            do { try await store.loadNotificationDefaults() } catch is CancellationError {} catch {
                failure = error.localizedDescription
            }
        }
    }

    private func choice(
        _ title: LocalizedStringKey, mode: NotificationSettingMode = .temporarilyMuted,
        seconds: Int? = nil, selected: Bool = false
    ) -> some View {
        Button {
            guard !saving else { return }
            guard store.currentUserProfile?.uid == accountUID else {
                dismiss()
                return
            }
            saving = true
            failure = nil
            Task {
                defer { saving = false }
                do {
                    try await store.setNotificationSetting(
                        chatID: chat.id, request: .init(mode: mode, durationSeconds: seconds))
                    dismiss()
                } catch is CancellationError {} catch { failure = error.localizedDescription }
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityLabel("Selected") }
            }
        }
    }
}
