import Foundation

/// The language selected for Chahua's localized interface.
enum AppLanguage: String, CaseIterable, Identifiable {
    nonisolated static let storageKey = "app.chahua.language"

    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .system: Self.localized("System Default")
        case .english: Self.localized("English")
        case .simplifiedChinese: Self.localized("Simplified Chinese")
        case .traditionalChinese: Self.localized("Traditional Chinese")
        }
    }

    /// The locale used to render SwiftUI and eagerly-resolved localized strings.
    nonisolated var locale: Locale {
        switch self {
        case .system:
            .autoupdatingCurrent
        case .english, .simplifiedChinese, .traditionalChinese:
            Locale(identifier: rawValue)
        }
    }

    /// The persisted selection, falling back safely when an older or corrupt value is stored.
    nonisolated static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// Resolves a string using the current in-app language selection.
    ///
    /// Use this instead of `String(localized:)` where a `String` is required before
    /// SwiftUI renders it. SwiftUI's `Text` localizes from the locale environment directly.
    nonisolated static func localized(
        _ key: String.LocalizationValue,
        table: String? = nil,
        bundle: Bundle? = nil,
        comment: StaticString? = nil
    ) -> String {
        String(
            localized: key, table: table, bundle: bundle, locale: selected.locale, comment: comment)
    }
}
