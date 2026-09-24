import SwiftUI

/// Persisted presentation preferences for the conversation list.
enum ConversationListPreferences {
    static let showsMessagesTabStorageKey = "chat.list.showsMessagesTab"
    static let unreadBadgeColorStorageKey = "chat.list.unreadBadgeColor"

    static let defaultShowsMessagesTab = true
    static let defaultUnreadBadgeColor = ConversationUnreadBadgeColor.default
}

/// Named colors keep the unread badge picker understandable without relying on color alone.
enum ConversationUnreadBadgeColor: String, CaseIterable, Identifiable {
    case `default`
    case blue
    case indigo
    case purple
    case pink
    case red

    var id: Self { self }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .default: "Default"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        }
    }

    /// Each preset meets the 4.5:1 contrast target against the badge's white text.
    var color: Color {
        switch self {
        case .default:
            Color(.sRGB, red: 38.0 / 255, green: 112.0 / 255, blue: 192.0 / 255, opacity: 1)
        case .blue:
            Color(.sRGB, red: 0, green: 95.0 / 255, blue: 204.0 / 255, opacity: 1)
        case .indigo:
            Color(.sRGB, red: 55.0 / 255, green: 48.0 / 255, blue: 163.0 / 255, opacity: 1)
        case .purple:
            Color(.sRGB, red: 97.0 / 255, green: 55.0 / 255, blue: 148.0 / 255, opacity: 1)
        case .pink:
            Color(.sRGB, red: 183.0 / 255, green: 39.0 / 255, blue: 93.0 / 255, opacity: 1)
        case .red:
            Color(.sRGB, red: 187.0 / 255, green: 35.0 / 255, blue: 35.0 / 255, opacity: 1)
        }
    }
}
