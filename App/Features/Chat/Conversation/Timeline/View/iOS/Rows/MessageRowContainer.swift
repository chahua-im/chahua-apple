#if os(iOS)
import ChahuaAPI
import SwiftUI

/// Row affordances never participate in bubble geometry.
struct MessageRowContainer: View {
    let row: TimelineMessageRow
    let presentation: TimelineRowPresentation
    let layout: TimelineRowLayout
    let context: TimelineRowContext
    @Environment(\.messageBubbleActions) private var actions
    @Environment(\.colorScheme) private var colorScheme
    @State private var isRowHovered = false
    @State private var isReplyHovered = false

    private var canReply: Bool {
        !context.isInteractionPreview && actions.replyToMessage != nil
            && MessageActionPolicy(row: row, context: actions.interactionContext).availability(of: .reply) == .enabled
    }
    private func reply() {
        guard canReply, let message = row.entry.remoteMessage else { return }
        actions.replyToMessage?(message)
    }
    private var bubble: some View {
        MessageBubble(row: row, presentation: presentation, layout: layout, context: context, actions: actions)
    }

    var body: some View {
        if context.isInteractionPreview {
            bubble
        } else {
            messageRow
        }
    }

    private var messageRow: some View {
        TimelineSectionLayout(size: layout.size, frames: layout.frames) {
            if let frame = layout.frames[.bubble] {
                bubble
                    .frame(width: frame.width, height: frame.height)
                    .modifier(MessageContextSource(open: actions.openContextMenu.map { action in { rect in action(row, rect) } }))
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
                    .timelineSection(.bubble)
            }
            if let frame = layout.frames[.avatar] {
                avatar.frame(width: frame.width, height: frame.height).timelineSection(.avatar)
            }
            if let frame = layout.frames[.reactions], let reactions = row.entry.remoteMessage?.reactions {
                BubbleReactions(reactions: reactions, isOutgoing: row.isOutgoing, size: frame.size, itemFrames: layout.reactionFrames, isPending: actions.pendingReactionMessageIDs.contains(row.entry.remoteMessage?.id ?? ""), toggle: !MessageActionPolicy(row: row, context: actions.interactionContext).canReact ? nil : actions.toggleReaction.map { action in { emoji in action(row, emoji) } })
                    .timelineSection(.reactions)
            }
            if let frame = layout.frames[.thread], let label = presentation.threadLabel {
                MessageThreadIndicator(label: label, fontSize: presentation.environment.captionSize, symbolSize: layout.threadSymbolSize, labelGap: layout.threadLabelGap, action: row.entry.remoteMessage.flatMap { message in actions.openThread.map { action in { action(message.id) } } })
                    .frame(width: frame.width, height: frame.height)
                    .foregroundStyle(ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme))
                    .timelineSection(.thread)
            }
        }
        .contentShape(Rectangle())
        .onHover { isRowHovered = $0 }
        .modifier(MessageReplySwipe(isEnabled: canReply, onReply: reply))
        .id(row.entry.stableKey)
        .onChange(of: row.entry.stableKey) { _, _ in
            isRowHovered = false
            isReplyHovered = false
        }
        .onChange(of: canReply) { _, enabled in if !enabled { isReplyHovered = false } }
        .onDisappear {
            isRowHovered = false
            isReplyHovered = false
        }
    }

    private var pendingSenderProfile: MeResponse? {
        guard row.entry.remoteMessage == nil, let profile = actions.currentUserProfile, profile.uid == row.entry.senderID else { return nil }
        return profile
    }
    private var avatar: some View {
        AvatarView(url: (row.entry.remoteMessage?.sender.avatarUrl ?? pendingSenderProfile?.avatarUrl).flatMap(URL.init(string:)), displayName: row.entry.remoteMessage?.sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? pendingSenderProfile?.username ?? "User \(row.entry.senderID)", diameter: presentation.environment.avatarSize)
    }
}


#endif
