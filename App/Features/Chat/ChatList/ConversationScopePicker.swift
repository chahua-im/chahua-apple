import SwiftUI

struct ConversationScopePicker: View {
    @Binding var selection: ConversationListScope

    var body: some View {
        Picker("Conversation scope", selection: $selection) {
            Text("Messages").tag(ConversationListScope.messages)
            Text("Groups").tag(ConversationListScope.groups)
            Text("DMs").tag(ConversationListScope.dms)
            Text("Threads").tag(ConversationListScope.threads)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
