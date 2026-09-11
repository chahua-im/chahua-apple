import ChahuaAPI
import SwiftUI

/// Shared row geometry and reactions, independent of the message's content surface.
struct MessageBubbleShell<Content: View>: View {
    let row: TimelineMessageRow
    var context: TimelineRowContext = .init()
    var styled = true
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.messageBubbleActions) private var actions
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = BubbleMetrics.avatarSize
    @State private var isRowHovered = false
    @State private var isReplyHovered = false

    private var canReply: Bool {
        !context.isMeasuring && !context.isInteractionPreview
            && actions.replyToMessage != nil
            && MessageActionPolicy(row: row, context: actions.interactionContext).availability(of: .reply) == .enabled
    }

    private func reply() {
        guard canReply, let message = row.entry.remoteMessage else { return }
        actions.replyToMessage?(message)
    }

    var body: some View {
        if context.isInteractionPreview {
            surface
        } else {
            messageRow
        }
    }

    private var messageRow: some View {
        BubbleRowLayout(isOutgoing: row.isOutgoing, avatarSize: avatarSize) {
            surface
                .modifier(
                    MessageContextSource(
                        open: context.isMeasuring
                            ? nil
                            : actions.openContextMenu.map { action in
                                { rect in action(row, rect) }
                            }))
                .overlay(alignment: row.isOutgoing ? .bottomLeading : .bottomTrailing) {
                    if canReply && isRowHovered {
                        MessageRowActionButton(action: reply) {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.system(size: 16))
                                .foregroundStyle(isReplyHovered ? ChahuaTheme.accent : .secondary)
                                .frame(width: 28, height: 28)
                                .background(.primary.opacity(isReplyHovered ? 0.12 : 0.06), in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reply")
                        .help("Reply")
                        .onHover { isReplyHovered = $0 }
                        .offset(x: row.isOutgoing ? -36 : 36)
                    }
                }
            avatar
            if row.entry.remoteMessage?.isDeleted != true,
                let reactions = row.entry.remoteMessage?.reactions, !reactions.isEmpty
            {
                BubbleReactions(
                    reactions: reactions, isOutgoing: row.isOutgoing, isMeasuring: context.isMeasuring,
                    isPending: actions.pendingReactionMessageIDs.contains(row.entry.remoteMessage?.id ?? ""),
                    toggle: context.isMeasuring
                        || !MessageActionPolicy(row: row, context: actions.interactionContext).canReact
                        ? nil : actions.toggleReaction.map { action in { emoji in action(row, emoji) } }
                )
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, BubbleMetrics.rowHorizontalInset)
        .padding(.vertical, BubbleMetrics.rowVerticalInset)
        .contentShape(Rectangle())
        .onHover { isRowHovered = $0 }
        .modifier(MessageReplySwipe(isEnabled: canReply, isMeasuring: context.isMeasuring, onReply: reply))
        .id(row.entry.stableKey)
        .onChange(of: row.entry.stableKey) { _, _ in
            isRowHovered = false
            isReplyHovered = false
        }
        .onChange(of: canReply) { _, enabled in
            if !enabled { isReplyHovered = false }
        }
    }

    @ViewBuilder private var surface: some View {
        if styled {
            content()
                .padding(.horizontal, BubbleMetrics.textHorizontalInset)
                .padding(.vertical, BubbleMetrics.textVerticalInset)
                .foregroundStyle(
                    row.isOutgoing
                        ? ChahuaTheme.ChatBubble.outgoingForeground
                        : ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme)
                )
                .background {
                    BubbleShape(
                        isOutgoing: row.isOutgoing, hasTail: row.groupPosition == .single || row.groupPosition == .last
                    )
                    .fill(
                        row.isOutgoing
                            ? ChahuaTheme.ChatBubble.outgoingBackground
                            : ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme))
                }
        } else {
            content()
        }
    }

    private var pendingSenderProfile: MeResponse? {
        guard row.entry.remoteMessage == nil,
            let profile = actions.currentUserProfile, profile.uid == row.entry.senderID
        else { return nil }
        return profile
    }

    @ViewBuilder private var avatar: some View {
        if !context.isMeasuring && (row.groupPosition == .single || row.groupPosition == .last) {
            AvatarView(
                url: (row.entry.remoteMessage?.sender.avatarUrl ?? pendingSenderProfile?.avatarUrl)
                    .flatMap(URL.init(string:)),
                displayName: row.entry.remoteMessage?.sender.name.flatMap { $0.isEmpty ? nil : $0 }
                    ?? pendingSenderProfile?.username
                    ?? "User \(row.entry.senderID)",
                diameter: avatarSize
            )
        } else {
            Color.clear.frame(width: avatarSize, height: avatarSize)
        }
    }
}
