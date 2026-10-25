import SwiftUI

/// Device-local appearance; System clears the native override.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "app.appearance"
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

}

extension View {
    func appAppearance() -> some View {
        modifier(AppAppearanceModifier())
    }
}

private struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    func body(content: Content) -> some View {
        content.background {
            NativeAppAppearance(appearance: AppAppearance(rawValue: appearance) ?? .system)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
