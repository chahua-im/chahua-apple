import SwiftUI

struct ConversationListHeader<Account: View>: View {
    @Binding var selection: ConversationListScope
    var badges = ConversationTabBadges()
    var onBack: (() -> Void)?
    @ViewBuilder let account: () -> Account

    var body: some View {
        #if os(iOS)
            HStack(spacing: 8) {
                leadingControl
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: true))
                    .accessibilityLabel(onBack == nil ? Text("Account") : Text("Back to chats"))
                ConversationScopePicker(selection: $selection, badges: badges)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(onBack == nil ? Text("Chats") : Text("Archived"))
        #else
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.backward")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .help("Back to chats")
                        .accessibilityLabel("Back to chats")
                    } else {
                        account()
                            .dynamicTypeSize(.medium)
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .frame(width: 26, height: 26)
                            .clipShape(Circle())
                    }
                    Text(onBack == nil ? "Chats" : "Archived")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    // Visual prototype: composing a new message is not connected yet.
                    Button {
                    } label: {
                        Label("New message", systemImage: "square.and.pencil")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 18))
                            .frame(width: 32, height: 32)
                    }
                    .help("New message")
                    .disabled(true)
                }
                ConversationScopePicker(selection: $selection, badges: badges)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            #if !os(macOS)
                // macOS already reserves vertical clearance in the window-controls row.
                .padding(.top, 12)
            #endif
            .background(alignment: .bottom) { Divider() }
        #endif
    }

    @ViewBuilder
    private var leadingControl: some View {
        if let onBack {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        } else {
            account()
        }
    }
}
