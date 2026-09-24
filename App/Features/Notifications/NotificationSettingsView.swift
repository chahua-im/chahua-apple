import ChahuaAPI
import SwiftUI
import UserNotifications

enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance, conversations, notifications, storage, account

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .appearance: "Appearance"
        case .conversations: "Conversations"
        case .notifications: "Notifications"
        case .storage: "Storage"
        case .account: "Account"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .conversations: "bubble.left.and.bubble.right"
        case .notifications: "bell"
        case .storage: "internaldrive"
        case .account: "person.crop.circle"
        }
    }
}

struct NotificationSettingsView: View {
    @ObservedObject var notifications: PushNotificationCoordinator
    @ObservedObject var chatStore: ChatStore
    let username: String
    let isSigningOut: Bool
    let onSignOut: () -> Void
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @AppStorage(ConversationListPreferences.showsMessagesTabStorageKey)
    private var showsMessagesTab = true
    @AppStorage(MessageTextSizePreference.storageKey)
    private var messageTextSize = MessageTextSizePreference.defaultValue
    @AppStorage(ConversationListPreferences.unreadBadgeColorStorageKey)
    private var unreadBadgeColor = ConversationUnreadBadgeColor.default.rawValue
    @Environment(\.mediaContext) private var mediaContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            #if os(macOS)
                MacSettingsNavigationView(settings: self)
            #else
                IOSSettingsNavigationView(settings: self)
            #endif
        }
        .task { await notifications.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await notifications.refreshAuthorization() }
            }
        }
    }

    var accountSummary: some View {
        HStack(spacing: 16) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(ChahuaTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(username)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text("Your space, your way")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    func page(_ page: SettingsPage, grouped: Bool) -> some View {
        if grouped {
            Form {
                if page == .account {
                    Section { accountSummary }
                }
                Section {
                    pageRows(page, showsDividers: false)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(page.title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if page == .account { accountSummary }
                    Label(page.title, systemImage: page.symbol)
                        .font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 16) {
                        pageRows(page, showsDividers: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .navigationTitle(page.title)
        }
    }

    @ViewBuilder
    private func pageRows(_ page: SettingsPage, showsDividers: Bool) -> some View {
        switch page {
        case .appearance:
            LabeledContent("App language") {
                Picker("App language", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.localizedTitle).tag(option.rawValue)
                    }
                }
                .labelsHidden()
            }
            if showsDividers { Divider() }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Message text size", systemImage: "textformat.size")
                    Spacer()
                    Text("\(messageTextSize) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(messageTextSize) },
                        set: { messageTextSize = Int($0.rounded()) }
                    ),
                    in: 14...18, step: 1
                )
                .accessibilityLabel("Message text size")
                HStack {
                    Text("14")
                    Spacer()
                    Text("18")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if showsDividers { Divider() }
            VStack(alignment: .leading, spacing: 12) {
                Text("Unread badge color")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 8)],
                    alignment: .leading, spacing: 8
                ) {
                    ForEach(ConversationUnreadBadgeColor.allCases) { option in
                        Button {
                            unreadBadgeColor = option.rawValue
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if unreadBadgeColor == option.rawValue {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .padding(3)
                                .overlay {
                                    Circle()
                                        .strokeBorder(
                                            unreadBadgeColor == option.rawValue
                                                ? option.color : .clear, lineWidth: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.localizedTitle)
                        .accessibilityAddTraits(
                            unreadBadgeColor == option.rawValue ? .isSelected : [])
                    }
                }
                Button("Reset to default") {
                    unreadBadgeColor = ConversationUnreadBadgeColor.default.rawValue
                }
                .disabled(unreadBadgeColor == ConversationUnreadBadgeColor.default.rawValue)
            }
        case .conversations:
            Toggle("Show Messages tab", isOn: $showsMessagesTab)
                .toggleStyle(.switch)
            Text("Groups, DMs, and Threads stay available when Messages is hidden.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .storage:
            if let mediaContext {
                MediaCacheSettingsSection(context: mediaContext)
                    .id(ObjectIdentifier(mediaContext))
            }
        case .notifications:
            LabeledContent("Authorization", value: authorizationDescription)
            LabeledContent(
                "APNs environment", value: environmentDescription(notifications.apnsEnvironment))
            #if os(macOS)
                LabeledContent(
                    "Signed entitlement",
                    value: environmentDescription(notifications.signedEnvironment))
                if let configured = notifications.configuredEnvironment,
                    let signed = notifications.signedEnvironment, configured != signed
                {
                    Text(
                        "The build configuration differs from its signed APNs entitlement. The signed environment is used for registration."
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                } else if notifications.signedEnvironment == nil {
                    Text(
                        "No signed APNs entitlement was found. Push delivery requires a signed app with the Push Notifications capability."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            #else
                Text(
                    "iOS does not expose its signed APNs entitlement to apps. The environment above comes from this build's configuration."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
            LabeledContent("Device token") {
                if let suffix = notifications.deviceTokenSuffix {
                    Text(verbatim: "…\(suffix)")
                        .monospaced()
                        .textSelection(.enabled)
                } else {
                    Text("Not received")
                }
            }
            LabeledContent("Backend registration") {
                HStack {
                    if notifications.isRegistering {
                        ProgressView().controlSize(.small)
                    }
                    Text(registrationDescription)
                }
            }
            if let registered = notifications.backendEnvironment {
                LabeledContent(
                    "Registered environment", value: environmentDescription(registered))
            }
            if let error = notifications.registrationError {
                Text(verbatim: error).foregroundStyle(.red)
            }
            if showsDividers { Divider() }
            if notifications.canDisableNotifications {
                Button("Disable notifications", role: .destructive) {
                    Task { await notifications.disableNotifications() }
                }
                .disabled(notifications.isUnregistering || isSigningOut)
                if !notifications.isRegistered {
                    Button("Retry registration") {
                        Task { await notifications.refreshAuthorization() }
                    }
                    .disabled(
                        notifications.isRegistering || notifications.isUnregistering || isSigningOut
                    )
                }
            } else {
                Button("Enable notifications") {
                    Task { await notifications.requestAuthorization() }
                }
                .disabled(
                    notifications.isRegistering || notifications.isUnregistering || isSigningOut)
            }
            Button("Open System Settings") { notifications.openSystemSettings() }
        case .account:
            Button {
                Task { await chatStore.refreshActiveConversations() }
            } label: {
                Label("Refresh chats", systemImage: "arrow.clockwise")
            }
            .disabled(
                chatStore.state.isRefreshingChats || chatStore.state.isRefreshingThreads
                    || isSigningOut)
            if showsDividers { Divider() }
            Button("Sign out", role: .destructive) { onSignOut() }
                .disabled(isSigningOut || notifications.isUnregistering)
        }
    }

    private func environmentDescription(_ environment: APNsEnvironment?) -> String {
        switch environment {
        case .sandbox: AppLanguage.localized("Sandbox")
        case .production: AppLanguage.localized("Production")
        case nil: AppLanguage.localized("Unavailable")
        }
    }

    private var authorizationDescription: String {
        switch notifications.authorizationStatus {
        case .notDetermined: AppLanguage.localized("Not requested")
        case .denied: AppLanguage.localized("Denied")
        case .authorized: AppLanguage.localized("Allowed")
        case .provisional: AppLanguage.localized("Quiet delivery")
        #if os(iOS)
            case .ephemeral: AppLanguage.localized("Temporary access")
        #endif
        @unknown default: AppLanguage.localized("Unknown")
        }
    }

    private var registrationDescription: String {
        if notifications.isUnregistering { return AppLanguage.localized("Unregistering…") }
        if notifications.notificationsDisabled {
            return AppLanguage.localized("Disabled on this device")
        }
        if notifications.isRegistering { return AppLanguage.localized("Registering…") }
        return notifications.isRegistered
            ? AppLanguage.localized("Registered")
            : AppLanguage.localized("Not registered")
    }
}
