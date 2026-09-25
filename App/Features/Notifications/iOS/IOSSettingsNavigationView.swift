#if os(iOS)
    import SwiftUI

    // iOS uses a pushed settings hierarchy so phones and iPads retain native back navigation.
    // A single SwiftUI settings form cannot provide the separate category destinations.
    struct IOSSettingsNavigationView: View {
        let settings: NotificationSettingsView
        @Environment(\.dismiss) private var dismiss
        @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

        private var settingsTitle: String {
            SettingsPage.navigationTitle(languageRawValue: language)
        }

        var body: some View {
            NavigationStack {
                List {
                    settings.accountSummary
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    Section("General") {
                        ForEach(SettingsPage.generalPages) { page in
                            NavigationLink(value: page) {
                                Label(page.title, systemImage: page.symbol)
                            }
                        }
                    }
                    Section("Stickers") {
                        settings.autoSortPacksRow
                        settings.autoSortFavoritesRow
                        ForEach(SettingsPage.stickerPages) { page in
                            NavigationLink(value: page) {
                                Label(page.title, systemImage: page.symbol)
                            }
                        }
                    }
                    Section("Notifications") {
                        NavigationLink(value: SettingsPage.notifications) {
                            Label(SettingsPage.notifications.title, systemImage: "bell")
                        }
                    }
                    Section {
                        settings.signOutRow
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(settingsTitle)
                .navigationDestination(for: SettingsPage.self) { page in
                    settings.page(page, grouped: true)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
    }
#endif
