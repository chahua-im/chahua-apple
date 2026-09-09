import ChahuaAPI
import SwiftUI

struct TimelineRowContext: Equatable {
    var isHighlighted = false
    var viewportSize: CGSize = .zero
    var currentUserID: Int32?
    var isThreadTimeline = false
    var isMeasuring = false
}

struct TimelineBubbleActions {
    var openMedia: ((String, [AttachmentResponse], String) -> Void)?
    var openReply: ((String) -> Void)?
    var openThread: ((String) -> Void)?
    var openLink: ((URL) -> Void)?
    var openMention: ((Int32) -> Void)?
    var openFailedMessage: ((String) -> Void)?
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
            case .message(let message):
                messageBody(message)
            }
        }
        .background(context.isHighlighted ? ChahuaTheme.accent.opacity(0.15) : .clear)
        .animation(.easeOut(duration: 0.3), value: context.isHighlighted)
        .environment(\.mediaContext, mediaContext)
    }

    @ViewBuilder
    private func messageBody(_ row: TimelineMessageRow) -> some View {
        if row.entry.remoteMessage?.isDeleted == true {
            DeletedMessageBubble(row: row)
        } else if row.entry.messageType == .system {
            SystemMessageBubble(row: row)
        } else if row.entry.messageType == .text {
            TextMessageBubble(row: row, context: context, actions: actions)
        } else {
            UnsupportedMessageBubble(row: row)
        }
    }
}
