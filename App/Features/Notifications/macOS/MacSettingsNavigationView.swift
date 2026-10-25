#if os(macOS)
    import SwiftUI

    // macOS keeps categories visible beside their detail, unlike iOS's pushed hierarchy.
    // NavigationSplitView is the native SwiftUI sidebar/detail container for this layout.
    struct MacSettingsNavigationView: View {
        let settings: NotificationSettingsView
        @State private var selection: SettingsPage? = .language
        @State private var previousSelection: SettingsPage? = .language
        @State private var protectsEditorEdits = false
        @Environment(\.dismiss) private var dismiss
        @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

        private var settingsTitle: String {
            SettingsPage.navigationTitle(languageRawValue: language)
        }

        var body: some View {
            NavigationSplitView {
                List(
                    selection: Binding(
                        get: { selection },
                        set: { if !protectsEditorEdits { selection = $0 } })
                ) {
                    settings.accountSummary
                        .listRowBackground(Color.clear)
                    Section("General") {
                        ForEach(SettingsPage.generalPages) { page in
                            Label(page.title, systemImage: page.symbol)
                                .tag(page)
                        }
                    }
                    Section("Privacy and Security") {
                        ForEach(SettingsPage.privacyPages) { page in
                            if page == .blockedUsers {
                                settings.blockedUsersRow
                                    .tag(page)
                            } else {
                                Label(page.title, systemImage: page.symbol)
                                    .tag(page)
                            }
                        }
                    }
                    Section("Stickers") {
                        ForEach(SettingsPage.stickerPages) { page in
                            Label(page.title, systemImage: page.symbol)
                                .tag(page)
                        }
                    }
                    Section("Notifications") {
                        Label(SettingsPage.notifications.title, systemImage: "bell")
                            .tag(SettingsPage.notifications)
                    }
                }
                .disabled(protectsEditorEdits)
                .safeAreaInset(edge: .bottom) {
                    settings.signOutRow
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 24)
                        .padding(.horizontal)
                        .padding(.bottom)
                }
                .navigationTitle(settingsTitle)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            } detail: {
                if let selection {
                    if selection == .friendRequestPermission {
                        FriendVerificationSettingsView(
                            store: settings.chatStore, grouped: false,
                            onFinish: { self.selection = previousSelection })
                    } else if selection == .readReceiptPrivacy {
                        ReadReceiptPrivacySettingsView(
                            store: settings.chatStore, grouped: false,
                            onFinish: { self.selection = previousSelection })
                    } else if selection == .presencePrivacy {
                        PresencePrivacySettingsView(
                            store: settings.chatStore, grouped: false,
                            onFinish: { self.selection = previousSelection })
                    } else if selection == .stickerPacks || selection == .notifications
                        || selection == .blockedUsers
                    {
                        NavigationStack {
                            settings.page(selection, grouped: false)
                        }
                    } else {
                        settings.page(selection, grouped: false)
                    }
                } else {
                    ContentUnavailableView("Select a setting", systemImage: "gearshape")
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .disabled(protectsEditorEdits)
                }
            }
            .onPreferenceChange(SettingsEditorExitProtectionKey.self) {
                protectsEditorEdits = $0
            }
            .onChange(of: selection) { old, new in
                if new == .friendRequestPermission || new == .readReceiptPrivacy
                    || new == .presencePrivacy,
                    old != .friendRequestPermission, old != .readReceiptPrivacy,
                    old != .presencePrivacy
                {
                    previousSelection = old
                }
            }
        }
    }
#endif
