import ChahuaAPI
import SwiftUI

/// Shared row geometry and reactions, independent of the message's content surface.
struct MessageBubbleShell<Content: View>: View {
    let row: TimelineMessageRow
    var context: TimelineRowContext = .init()
    var styled = true
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = BubbleMetrics.avatarSize

    var body: some View {
        BubbleRowLayout(isOutgoing: row.isOutgoing, avatarSize: avatarSize) {
            BubbleColumnLayout(alignment: row.isOutgoing ? .trailing : .leading) {
                surface
                if row.entry.remoteMessage?.isDeleted != true,
                   let reactions = row.entry.remoteMessage?.reactions, !reactions.isEmpty {
                    BubbleReactions(reactions: reactions, isOutgoing: row.isOutgoing, isMeasuring: context.isMeasuring)
                        .padding(.vertical, 8)
                }
            }
            avatar
        }
        .padding(.horizontal, BubbleMetrics.rowHorizontalInset)
        .padding(.vertical, BubbleMetrics.rowVerticalInset)
    }

    @ViewBuilder private var surface: some View {
        if styled {
            content()
                .padding(.horizontal, BubbleMetrics.textHorizontalInset)
                .padding(.vertical, BubbleMetrics.textVerticalInset)
                .foregroundStyle(row.isOutgoing ? ChahuaTheme.ChatBubble.outgoingForeground : ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme))
                .background {
                    BubbleShape(isOutgoing: row.isOutgoing, hasTail: row.groupPosition == .single || row.groupPosition == .last)
                        .fill(row.isOutgoing ? ChahuaTheme.ChatBubble.outgoingBackground : ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme))
                }
        } else {
            content()
        }
    }

    @ViewBuilder private var avatar: some View {
        if !context.isMeasuring && (row.groupPosition == .single || row.groupPosition == .last) {
            AvatarView(
                url: row.entry.remoteMessage?.sender.avatarUrl.flatMap(URL.init(string:)),
                displayName: row.entry.remoteMessage?.sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(row.entry.senderID)",
                diameter: avatarSize
            )
        } else {
            Color.clear.frame(width: avatarSize, height: avatarSize)
        }
    }
}
