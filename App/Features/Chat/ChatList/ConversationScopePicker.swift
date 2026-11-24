import SwiftUI

struct ConversationScopePicker: View {
    @Environment(\.isWideChatLayout) private var isWideChatLayout
    @Binding var selection: ConversationListScope
    var badges = ConversationTabBadges()
    var badgeColor = ConversationListPreferences.defaultUnreadBadgeColor
    // Cross-fade centered labels so an invisible badge cannot offset the visible title.
    var archivedBadges: ConversationTabBadges? = nil
    var archiveProgress: CGFloat = 0

    var body: some View {
        Group {
            if isWideChatLayout {
                widePicker
            } else {
                compactPicker
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation scope")
    }

    private var widePicker: some View {
        let desktop = ConversationListMetrics.usesDesktopDensity(isWide: isWideChatLayout)
        return HStack(spacing: 2) {
            ForEach(ConversationListScope.allCases) { scope in
                Button {
                    selection = scope
                } label: {
                    ZStack {
                        wideLabel(badges, scope: scope, desktop: desktop)
                            .opacity(archivedBadges == nil ? 1 : 1 - archiveProgress)
                        if let archivedBadges {
                            wideLabel(archivedBadges, scope: scope, desktop: desktop)
                                .opacity(archiveProgress)
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, minHeight: desktop ? 24 : 40)
                    .background {
                        if selection == scope {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.background)
                                .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(scope.localizedTitle))
                .accessibilityValue(
                    Text(
                        (archiveProgress >= 0.5 ? archivedBadges ?? badges : badges)
                            .accessibilityValue(for: scope))
                )
                .accessibilityAddTraits(selection == scope ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func wideLabel(
        _ values: ConversationTabBadges, scope: ConversationListScope, desktop: Bool
    ) -> some View {
        HStack(spacing: 3) {
            Text(scope.localizedTitle)
                .font(
                    .system(
                        size: desktop ? 12 : 14,
                        weight: selection == scope ? .semibold : .medium)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            wideBadge(values, scope: scope, desktop: desktop)
        }
    }

    @ViewBuilder
    private func wideBadge(
        _ values: ConversationTabBadges, scope: ConversationListScope, desktop: Bool
    ) -> some View {
        if let label = values.label(for: scope) {
            RoundChipLayout(isCircular: label.count == 1) {
                Text(label)
                    .font(.system(size: desktop ? 9 : 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
            }
            // The same content-sized circular capsule backs both cross-fade layers.
            .background(
                values.archived ? Color.gray : badgeColor.color,
                in: Capsule(style: .circular)
            )
            .accessibilityHidden(true)
        }
    }

    private var compactPicker: some View {
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
                            RoundChipLayout(isCircular: label.count == 1) {
                                Text(label)
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                            }
                            .background(
                                badges.archived ? Color.gray : badgeColor.color,
                                in: Capsule(style: .circular)
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
