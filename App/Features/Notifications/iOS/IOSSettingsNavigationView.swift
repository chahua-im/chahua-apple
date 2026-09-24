#if os(iOS)
    import SwiftUI

    // iOS uses a pushed settings hierarchy so phones and iPads retain native back navigation.
    // A single SwiftUI settings form cannot provide the separate category destinations.
    struct IOSSettingsNavigationView: View {
        let settings: NotificationSettingsView
        @Environment(\.dismiss) private var dismiss

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
                    Section("Push Notifications") {
                        NavigationLink(value: SettingsPage.notifications) {
                            Label(SettingsPage.notifications.title, systemImage: "bell")
                        }
                    }
                    Section {
                        settings.signOutRow
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Settings")
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
