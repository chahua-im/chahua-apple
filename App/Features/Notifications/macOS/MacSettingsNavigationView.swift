#if os(macOS)
    import SwiftUI

    // macOS always keeps the category sidebar visible; compact here denotes desktop metrics.
    struct MacSettingsNavigationView: View {
        let settings: NotificationSettingsView

        var body: some View {
            SettingsSplitNavigationView(settings: settings, compact: true)
        }
    }
#endif
