import ChahuaAPI
import SwiftUI

struct TimelineRowContext: Equatable {
    var isHighlighted = false
}

/// Closed rendering surface. Per-kind components live under `View/Bubble/`; adding a new row
/// requires an explicit case here rather than runtime registration.
struct TimelineBubbleView: View {
    let row: TimelineRow
    let context: TimelineRowContext

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
    }

    @ViewBuilder
    private func messageBody(_ row: TimelineMessageRow) -> some View {
        if row.entry.remoteMessage?.isDeleted == true {
            DeletedMessageBubble(row: row)
        } else if row.entry.messageType == .system {
            SystemMessageBubble(row: row)
        } else if row.entry.messageType == .text {
            TextMessageBubble(row: row)
        } else {
            UnsupportedMessageBubble(row: row)
        }
    }
}
