import SwiftUI

struct ConversationListHeader<Account: View>: View {
    @Binding var selection: ConversationListScope
    @ViewBuilder let account: () -> Account

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                account()
                    .dynamicTypeSize(.medium)
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                Text("Chats")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // Visual prototype: composing a new message is not connected yet.
                Button {} label: {
                    Label("New message", systemImage: "square.and.pencil")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 18))
                        .frame(width: 32, height: 32)
                }
                .help("New message")
                .disabled(true)
            }
            ConversationScopePicker(selection: $selection)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        #if !os(macOS)
        // macOS already reserves vertical clearance in the window-controls row.
        .padding(.top, 12)
        #endif
        .overlay(alignment: .bottom) { Divider() }
    }
}
