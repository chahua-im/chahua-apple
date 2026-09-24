import SwiftUI

struct ConversationScopePicker: View {
    @Binding var selection: ConversationListScope
    var badges = ConversationTabBadges()

    var body: some View {
        #if os(macOS)
            MacConversationScopePicker(selection: $selection, badges: badges)
        #else
            IOSConversationScopePicker(selection: $selection, badges: badges)
        #endif
    }
}

extension ConversationListScope {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .messages: "Messages"
        case .groups: "Groups"
        case .dms: "DMs"
        case .threads: "Threads"
        }
    }
}
