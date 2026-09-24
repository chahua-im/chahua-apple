#if os(macOS)
    import SwiftUI

    // macOS keeps categories visible beside their detail, unlike iOS's pushed hierarchy.
    // NavigationSplitView is the native SwiftUI sidebar/detail container for this layout.
    struct MacSettingsNavigationView: View {
        let settings: NotificationSettingsView
        @State private var selection: SettingsPage? = .appearance
        @Environment(\.dismiss) private var dismiss

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
                    Section("Push Notifications") {
                        Label(SettingsPage.notifications.title, systemImage: "bell")
                            .tag(SettingsPage.notifications)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    settings.signOutRow
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Settings")
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            } detail: {
                if let selection {
                    if selection == .stickers {
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
