import SwiftUI
import UserNotifications

struct PushNotificationSettingsPage<Diagnostics: View>: View {
    @ObservedObject var notifications: PushNotificationCoordinator
    @ObservedObject var store: ChatStore
    let isSigningOut: Bool
    let grouped: Bool
    @ViewBuilder let diagnostics: () -> Diagnostics
    @State private var showsDiagnostics = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if grouped {
                Form {
                    Section {
                        pushToggle
                        permissionHelp
                    }
                    Section("Notification settings") {
                        AccountNotificationPreferencesView(store: store)
                    }
                    if showsDiagnostics {
                        Section("Debug") {
                            diagnostics()
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label("Push Notifications", systemImage: "bell")
                            .font(.title2.weight(.semibold))
                        settingsCard {
                            pushToggle
                            permissionHelp
                        }
                        Text("Notification settings")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        settingsCard {
                            AccountNotificationPreferencesView(store: store)
                        }
                        if showsDiagnostics {
                            Text("Debug")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            settingsCard { diagnostics() }
                        }
                    }
                    .frame(maxWidth: 620)
                    .padding(32)
                    .frame(maxWidth: .infinity)
                }
                .background(ChahuaTheme.conversationBackground(for: colorScheme))
            }
        }
        .navigationTitle("Push Notifications")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear { showsDiagnostics = false }
    }

    private var pushToggle: some View {
        HStack {
            Text("Enable Push Notifications")
            Spacer()
            Toggle(
                "Enable Push Notifications",
                isOn: Binding(
                    get: { notifications.canDisableNotifications },
                    set: { enabled in
                        Task {
                            if enabled {
                                await notifications.requestAuthorization()
                            } else {
                                await notifications.disableNotifications()
                            }
                        }
                    })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(notifications.isRegistering || notifications.isUnregistering || isSigningOut)
        }
        .contentShape(Rectangle())
        // A simultaneous gesture leaves the switch's normal interaction intact.
        .simultaneousGesture(TapGesture(count: 5).onEnded { showsDiagnostics = true })
    }

    @ViewBuilder
    private var permissionHelp: some View {
        if notifications.authorizationStatus == .denied {
            Text("Allow notifications in System Settings to enable push notifications.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Open System Settings") { notifications.openSystemSettings() }
        }
        if let error = notifications.registrationError, !showsDiagnostics {
            Text(verbatim: error).foregroundStyle(.red)
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
}
