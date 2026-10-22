import SwiftUI

/// Shared navigation chrome for both the SwiftUI timeline and the native macOS table.
struct TimelineNavigationControls: View {
    let showsJumpToLatest: Bool
    let unreadMessageCount: Int64
    let unreadMentionCount: Int
    let unreadReactionCount: Int
    let isBusy: Bool
    let badgeColor: ConversationUnreadBadgeColor
    let jumpToLatest: () -> Void
    let jumpToMention: () -> Void
    let jumpToReaction: () -> Void

    @ScaledMetric(relativeTo: .caption2) private var badgeDiameter: CGFloat = 22

    private var controlDiameter: CGFloat {
        #if os(macOS)
            32
        #else
            44
        #endif
    }

    var body: some View {
        VStack(spacing: ChahuaTheme.Spacing.medium) {
            if unreadReactionCount > 0 {
                navigationButton(
                    symbol: "heart.fill", count: Int64(unreadReactionCount),
                    label: "Jump to next reaction",
                    value: AppLanguage.localized("\(unreadReactionCount) unread reactions"),
                    action: jumpToReaction)
            }
            if unreadMentionCount > 0 {
                navigationButton(
                    symbol: "at", count: Int64(unreadMentionCount),
                    label: "Jump to next mention or reply",
                    value: AppLanguage.localized(
                        "\(unreadMentionCount) unread mentions and replies"),
                    action: jumpToMention)
            }
            if showsJumpToLatest {
                navigationButton(
                    symbol: "chevron.down", count: unreadMessageCount,
                    label: "Jump to latest messages",
                    value: unreadMessageCount > 0
                        ? AppLanguage.localized("\(unreadMessageCount) unread messages") : "",
                    action: jumpToLatest)
            }
        }
        .disabled(isBusy)
        // Include the badge overhang in the hosted view's bounds and hit region.
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    private func navigationButton(
        symbol: String, count: Int64, label: LocalizedStringKey, value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            navigationSymbol(symbol)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count > 999 ? "999+" : String(count))
                            .font(.caption2.bold())
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .frame(minWidth: badgeDiameter, minHeight: badgeDiameter)
                            .foregroundStyle(.white)
                            .background(badgeColor.color, in: Capsule())
                            .offset(x: 8, y: -8)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(value)
        .help(Text(label))
    }

    @ViewBuilder
    private func navigationSymbol(_ symbol: String) -> some View {
        let image = Image(systemName: symbol)
            .font(.headline)
            .frame(width: controlDiameter, height: controlDiameter)
            .contentShape(Circle())
        if #available(macOS 26, iOS 26, *) {
            image.glassEffect(.regular.interactive(), in: Circle())
        } else {
            image.background(.regularMaterial, in: Circle())
        }
    }
}
