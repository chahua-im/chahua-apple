import SwiftUI

/// Visual prototype only: selection intentionally does not filter conversations.
struct ConversationScopePicker: View {
    @State private var selection = Scope.messages

    private enum Scope: Hashable {
        case messages, groups, dms, threads
    }

    var body: some View {
        Picker("Conversation scope", selection: $selection) {
            Text("Messages").tag(Scope.messages)
            Text("Groups").tag(Scope.groups)
            Text("DMs").tag(Scope.dms)
            Text("Threads").tag(Scope.threads)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
