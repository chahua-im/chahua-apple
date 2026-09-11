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
    var attachmentProgress: [String: Double] = [:]
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

/// Closed rendering surface. Per-kind components live under `View/Bubble/`; adding a new row
/// requires an explicit case here rather than runtime registration.
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
                messageBody(message)
            }
        }
        .background(context.isHighlighted ? ChahuaTheme.accent.opacity(0.15) : .clear)
        .animation(.easeOut(duration: 0.3), value: context.isHighlighted)
        .environment(\.mediaContext, mediaContext)
        .environment(\.messageBubbleActions, actions)
    }

    @ViewBuilder
    private func messageBody(_ row: TimelineMessageRow) -> some View {
        if row.entry.messageType == .system {
            SystemMessageBubble(row: row)
        } else if row.entry.remoteMessage?.isDeleted == true {
            DeletedMessageBubble(row: row, context: context)
        } else if row.entry.messageType == .text || row.entry.messageType == .sticker {
            ChatMessageBubble(row: row, context: context, actions: actions)
        } else {
            UnsupportedMessageBubble(row: row, context: context)
        }
    }
}
