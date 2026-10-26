import SwiftUI

struct ConversationScopePicker: View {
    @Binding var selection: ConversationListScope
    var badges = ConversationTabBadges()
    var badgeColor = ConversationListPreferences.defaultUnreadBadgeColor

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ConversationListScope.allCases) { scope in
                Button {
                    selection = scope
                } label: {
                    HStack(spacing: 4) {
                        Text(scope.localizedTitle)
                            .font(.subheadline.weight(selection == scope ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.bottom, 3)
                            .frame(minHeight: 44)
                        if let label = badges.label(for: scope) {
                            Text(label)
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    badges.archived ? Color.gray : badgeColor.color,
                                    in: Capsule()
                                )
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(selection == scope ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selection == scope ? Color.blue : Color.clear)
                            .frame(height: 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(scope.localizedTitle))
                .accessibilityValue(Text(badges.accessibilityValue(for: scope)))
                .accessibilityAddTraits(selection == scope ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation scope")
    }
}

extension ConversationListScope {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .messages: "All"
        case .groups: "Groups"
        case .dms: "DMs"
        case .threads: "Threads"
        }
    }
}
