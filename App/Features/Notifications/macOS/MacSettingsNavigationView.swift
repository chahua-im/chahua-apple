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
                    ForEach(SettingsPage.allCases) { page in
                        Label(page.title, systemImage: page.symbol)
                            .tag(page)
                    }
                }
                .navigationTitle("Settings")
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            } detail: {
                if let selection {
                    settings.page(selection, grouped: false)
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
