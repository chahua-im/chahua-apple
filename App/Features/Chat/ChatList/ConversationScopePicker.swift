import SwiftUI

struct ConversationScopePicker: View {
    @Binding var selection: ConversationListScope
    var badges = ConversationTabBadges()
    var showsMessagesTab = ConversationListPreferences.defaultShowsMessagesTab
    var badgeColor = ConversationListPreferences.defaultUnreadBadgeColor

    var body: some View {
        #if os(macOS)
            MacConversationScopePicker(
                selection: $selection, badges: badges, showsMessagesTab: showsMessagesTab,
                badgeColor: badgeColor)
        #else
            IOSConversationScopePicker(
                selection: $selection, badges: badges, showsMessagesTab: showsMessagesTab,
                badgeColor: badgeColor)
        #endif
    }
}

extension ConversationListScope {
    static func pickerScopes(showsMessagesTab: Bool) -> [Self] {
        showsMessagesTab ? allCases : allCases.filter { $0 != .messages }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .messages: "Messages"
        case .groups: "Groups"
        case .dms: "DMs"
        case .threads: "Threads"
        }
    }
}
