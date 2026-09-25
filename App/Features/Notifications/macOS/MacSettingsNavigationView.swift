#if os(macOS)
    import SwiftUI

    // macOS keeps categories visible beside their detail, unlike iOS's pushed hierarchy.
    // NavigationSplitView is the native SwiftUI sidebar/detail container for this layout.
    struct MacSettingsNavigationView: View {
        let settings: NotificationSettingsView
        @State private var selection: SettingsPage? = .language
        @Environment(\.dismiss) private var dismiss
        @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

        private var settingsTitle: String {
            SettingsPage.navigationTitle(languageRawValue: language)
        }

        var body: some View {
            NavigationSplitView {
                List(selection: $selection) {
                    settings.accountSummary
                        .listRowBackground(Color.clear)
                    Section("General") {
                        ForEach(SettingsPage.generalPages) { page in
                            Label(page.title, systemImage: page.symbol)
                                .tag(page)
                        }
                    }
                    Section("Stickers") {
                        settings.autoSortPacksRow
                        settings.autoSortFavoritesRow
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
                    if selection == .stickerPacks {
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
                }
            }
        }
    }
#endif
