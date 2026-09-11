import SwiftUI

struct UnsupportedMessageBubble: View {
    let row: TimelineMessageRow
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Label("This message type isn’t supported yet", systemImage: "questionmark.square.dashed")
            .padding(.horizontal, BubbleMetrics.textHorizontalInset)
            .padding(.vertical, BubbleMetrics.textVerticalInset)
            .foregroundStyle(
                row.isOutgoing
                    ? ChahuaTheme.ChatBubble.outgoingForeground
                    : ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme)
            )
            .modifier(MessageBubbleSurface(
                isOutgoing: row.isOutgoing,
                hasTail: row.groupPosition == .single || row.groupPosition == .last
            ))
    }
}
