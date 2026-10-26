#if os(macOS)
    import ChahuaAPI
    import SwiftUI

    // macOS keeps categories visible beside their detail, unlike iOS's pushed hierarchy.
    // NavigationSplitView is the native SwiftUI sidebar/detail container for this layout.
    struct MacSettingsNavigationView: View {
        let settings: NotificationSettingsView
        @State private var selection: SettingsPage? = .language
        @State private var previousSelection: SettingsPage?
        @State private var protectsEditorEdits = false
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationSplitView {
                List(
                    selection: Binding(
                        get: { selection },
                        set: { if !protectsEditorEdits { selection = $0 } })
                ) {
                    settings.accountSummary()
                        .listRowBackground(Color.clear)
                    Section {
                        SettingsPageLabel(page: .savedMessages)
                            .tag(SettingsPage.savedMessages)
                    }
                    Section("General") {
                        ForEach(SettingsPage.generalPages) { page in
                            SettingsPageLabel(page: page)
                                .tag(page)
                        }
                    }
                    Section("Privacy and Security") {
                        ForEach(SettingsPage.privacyPages) { page in
                            if page == .blockedUsers {
                                settings.blockedUsersRow
                                    .tag(page)
                            } else {
                                SettingsPageLabel(page: page)
                                    .tag(page)
                            }
                        }
                    }
                    Section("Stickers") {
                        ForEach(SettingsPage.stickerPages) { page in
                            SettingsPageLabel(page: page)
                                .tag(page)
                        }
                    }
                    Section("Notifications") {
                        SettingsPageLabel(page: .notifications)
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
                .navigationTitle("")
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            } detail: {
                if let selection {
                    if selection == .language {
                        LanguageSettingsView(
                            store: settings.chatStore,
                            onFinish: { self.selection = previousSelection }
                        )
                        .id("\(settings.me.uid)-\(settings.chatStore.sessionRevision)")
                    } else if selection == .friendRequestPermission {
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
                        || selection == .blockedUsers || selection == .savedMessages
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
                ToolbarItem(placement: .navigation) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                        .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: true))
                        .disabled(protectsEditorEdits)
                }
            }
            .onPreferenceChange(SettingsEditorExitProtectionKey.self) {
                protectsEditorEdits = $0
            }
            .onChange(of: selection) { old, new in
                if new == .language || new == .friendRequestPermission || new == .readReceiptPrivacy
                    || new == .presencePrivacy,
                    old != .language, old != .friendRequestPermission,
                    old != .readReceiptPrivacy, old != .presencePrivacy
                {
                    previousSelection = old
                }
            }
        }
    }
#endif
