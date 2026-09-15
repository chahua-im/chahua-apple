import SwiftUI

struct ConversationScopePicker: View {
    @Binding var selection: ConversationListScope
    var badges = ConversationTabBadges()

    var body: some View {
        // Segmented Picker labels cannot render a separate colored count badge.
        // Keep the control in SwiftUI so labels and badges share layout and hit targets.
        ViewThatFits(in: .horizontal) {
            segments(stacked: false).fixedSize(horizontal: true, vertical: false)
            segments(stacked: true)
        }
        .padding(3)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation scope")
    }

    private func segments(stacked: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(ConversationListScope.allCases) { scope in
                Button {
                    selection = scope
                } label: {
                    let layout = stacked ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 4))
                    layout {
                        Text(title(for: scope))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if badges[scope] > 0 {
                            Text(badges[scope] > 999 ? "999+" : String(badges[scope]))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                                .fixedSize()
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.subheadline.weight(selection == scope ? .semibold : .regular))
                    .padding(.horizontal, 6)
                    .padding(.vertical, stacked ? 4 : 0)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background {
                        if selection == scope {
                            Capsule().fill(.background)
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title(for: scope)))
                .accessibilityValue(badges[scope] > 0 ? Text("\(badges[scope]) unread conversations") : Text(""))
                .accessibilityAddTraits(selection == scope ? .isSelected : [])
            }
        }
    }

    private func title(for scope: ConversationListScope) -> LocalizedStringKey {
        switch scope {
        case .messages: "Messages"
        case .groups: "Groups"
        case .dms: "DMs"
        case .threads: "Threads"
        }
    }
}
