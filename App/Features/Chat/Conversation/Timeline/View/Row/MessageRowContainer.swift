import ChahuaAPI
import SwiftUI

/// Owns message alignment and surrounding affordances, never the bubble's surface.
struct MessageRowContainer<Content: View>: View {
    let row: TimelineMessageRow
    var context: TimelineRowContext = .init()
    @ViewBuilder let content: () -> Content
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
        if context.isInteractionPreview || row.entry.messageType == .system {
            content()
        } else {
            messageRow
        }
    }

    private var messageRow: some View {
        MessageRowLayout(isOutgoing: row.isOutgoing, avatarSize: avatarSize) {
            content()
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
            accessories
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

    private var accessories: some View {
        VStack(alignment: row.isOutgoing ? .trailing : .leading, spacing: 0) {
            if row.entry.remoteMessage?.isDeleted != true {
                if let reactions = row.entry.remoteMessage?.reactions, !reactions.isEmpty {
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
