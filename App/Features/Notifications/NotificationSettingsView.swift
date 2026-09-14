import ChahuaAPI
import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @ObservedObject var notifications: PushNotificationCoordinator
    @ObservedObject var chatStore: ChatStore
    let username: String
    let isSigningOut: Bool
    let onSignOut: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Username", value: username)
                }
                Section("Notifications") {
                    LabeledContent("Authorization", value: authorizationDescription)
                    LabeledContent("Registration") {
                        HStack {
                            if notifications.isRegistering {
                                ProgressView().controlSize(.small)
                            }
                            Text(registrationDescription)
                        }
                    }
                    if let error = notifications.registrationError {
                        Text(verbatim: error)
                            .foregroundStyle(.red)
                    }
                    if notifications.canDisableNotifications {
                        Button("Disable notifications", role: .destructive) {
                            Task { await notifications.disableNotifications() }
                        }
                        .disabled(notifications.isUnregistering || isSigningOut)
                    } else {
                        Button("Enable notifications") {
                            Task { await notifications.requestAuthorization() }
                        }
                        .disabled(notifications.isRegistering || notifications.isUnregistering || isSigningOut)
                    }
                    Button("Open System Settings") {
                        notifications.openSystemSettings()
                    }
                }
                Section {
                    Button {
                        Task { await chatStore.refreshActiveConversations() }
                    } label: {
                        Label("Refresh chats", systemImage: "arrow.clockwise")
                    }
                    .disabled(chatStore.state.isRefreshingChats || chatStore.state.isRefreshingThreads || isSigningOut)
                    Button("Sign out", role: .destructive) {
                        onSignOut()
                    }
                    .disabled(isSigningOut || notifications.isUnregistering)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await notifications.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await notifications.refreshAuthorization() }
            }
        }
    }

    private var authorizationDescription: String {
        switch notifications.authorizationStatus {
        case .notDetermined: String(localized: "Not requested")
        case .denied: String(localized: "Denied")
        case .authorized: String(localized: "Allowed")
        case .provisional: String(localized: "Quiet delivery")
        #if os(iOS)
        case .ephemeral: String(localized: "Temporary access")
        #endif
        @unknown default: String(localized: "Unknown")
        }
    }

    private var registrationDescription: String {
        if notifications.isUnregistering { return String(localized: "Unregistering…") }
        if notifications.notificationsDisabled { return String(localized: "Disabled on this device") }
        if notifications.isRegistering { return String(localized: "Registering…") }
        return notifications.isRegistered
            ? String(localized: "Registered")
            : String(localized: "Not registered")
    }
}
