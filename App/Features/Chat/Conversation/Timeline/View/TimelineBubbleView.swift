import ChahuaAPI
import SwiftUI

struct TimelineRowContext: Equatable {
    var isHighlighted = false
    var viewportSize: CGSize = .zero
    var currentUserID: Int32?
    var isThreadTimeline = false
    var isMeasuring = false
    var isInteractionPreview = false
}

struct TimelineBubbleActions {
    var openMedia: ((String, [AttachmentResponse], String) -> Void)?
    var openReply: ((String) -> Void)?
    var replyToMessage: ((MessageResponse) -> Void)?
    var editMessage: ((MessageResponse) -> Void)?
    var openThread: ((String) -> Void)?
    var openLink: ((URL) -> Void)?
    var openMention: ((Int32) -> Void)?
    var openFailedMessage: ((String) -> Void)?
    var openContextMenu: ((TimelineMessageRow, CGRect) -> Void)?
    var toggleReaction: ((TimelineMessageRow, String) -> Void)?
    var pendingReactionMessageIDs: Set<String> = []
    var currentUserProfile: MeResponse?
    var interactionContext = MessageInteractionContext()
    var modifiablePendingMessageIDs: Set<String> = []
    var blockPendingMessage: ((PendingOutgoingMessage) -> Void)?
    var revokePendingMessage: ((PendingOutgoingMessage) -> Void)?
}

private struct MessageBubbleActionsKey: EnvironmentKey {
    static var defaultValue: TimelineBubbleActions { .init() }
}

extension EnvironmentValues {
    var messageBubbleActions: TimelineBubbleActions {
        get { self[MessageBubbleActionsKey.self] }
        set { self[MessageBubbleActionsKey.self] = newValue }
    }
}

/// Separators render directly; every message shares one row container around its bubble.
struct TimelineBubbleView: View {
    let row: TimelineRow
    let context: TimelineRowContext
    let actions: TimelineBubbleActions
    let mediaContext: AppMediaContext?

    init(row: TimelineRow, context: TimelineRowContext, actions: TimelineBubbleActions = .init(), mediaContext: AppMediaContext? = nil) {
        self.row = row
        self.context = context
        self.actions = actions
        self.mediaContext = mediaContext
    }

    var body: some View {
        Group {
            switch row {
            case .dateSeparator(let separator):
                DateSeparatorBubble(row: separator)
            case .unreadSeparator:
                Text("Below are unread messages")
                    .font(.caption)
                    .foregroundStyle(ChahuaTheme.ChatBubble.outgoingBackground)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ChahuaTheme.Spacing.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ChahuaTheme.Spacing.medium)
            case .message(let message):
                MessageRowContainer(row: message, context: context) {
                    MessageBubble(row: message, context: context, actions: actions)
                }
            }
        }
        .background(context.isHighlighted ? ChahuaTheme.accent.opacity(0.15) : .clear)
        .animation(.easeOut(duration: 0.3), value: context.isHighlighted)
        .environment(\.mediaContext, mediaContext)
        .environment(\.messageBubbleActions, actions)
    }
}
