#if os(macOS)
    import AppKit
    import SwiftUI

    /// AppKit's application appearance reaches existing windows, attached sheets,
    /// and native panels together. Clearing it restores live system following,
    /// without relying on SwiftUI withdrawing a presentation preference.
    struct NativeAppAppearance: View {
        let appearance: AppAppearance
        private static let lightAppearance = NSAppearance(named: .aqua)
        private static let darkAppearance = NSAppearance(named: .darkAqua)

        var body: some View {
            Color.clear
                .onAppear { applyAppearance() }
                .onChange(of: appearance) { _, _ in applyAppearance() }
        }

        private func applyAppearance() {
            let nativeAppearance: NSAppearance? =
                switch appearance {
                case .system: nil
                case .light: Self.lightAppearance
                case .dark: Self.darkAppearance
                }
            if NSApp.appearance?.name != nativeAppearance?.name {
                NSApp.appearance = nativeAppearance
            }
        }
    }
#endif
