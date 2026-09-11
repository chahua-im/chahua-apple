import ChahuaAPI
import SwiftUI

/// Transparent sticker composition. Reply and metadata are shared message components,
/// not an empty text-message body or a special branch of TextMessageBubble.
struct StickerMessageBubble: View {
    let row: TimelineMessageRow
    let context: TimelineRowContext
    let actions: TimelineBubbleActions
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var metadataSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = BubbleMetrics.avatarSize

    private var availableWidth: CGFloat {
        BubbleMetrics.maximumBubbleWidth(rowWidth: context.viewportSize.width, avatarSize: avatarSize)
    }

    var body: some View {
        BubbleColumnLayout {
            if let preview = row.entry.replyToMessage, !preview.isDeleted {
                MessageReplyBanner(preview: preview, isOutgoing: row.isOutgoing, hasFilledBackground: false, openReply: actions.openReply)
                    .padding(.bottom, 6)
            }
            StickerContent(
                sticker: row.entry.remoteMessage?.sticker, viewport: context.viewportSize,
                availableWidth: availableWidth, isMeasuring: context.isMeasuring
            )
            .overlay(alignment: .bottomTrailing) {
                MessageMetadataView(
                    metadata: MessageMetadata(row: row, isOverlay: true, fontSize: metadataSize),
                    failureAction: failureAction
                )
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                .padding(4)
            }
            if !context.isThreadTimeline, let message = row.entry.remoteMessage, let count = message.threadInfo?.replyCount {
                MessageThreadIndicator(
                    count: count, isOutgoing: row.isOutgoing, showsSeparator: false,
                    action: actions.openThread.map { action in { action(message.id) } }
                )
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
        .frame(width: min(200, max(1, availableWidth)))
        .foregroundStyle(ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme))
    }

    private var failureAction: (() -> Void)? {
        guard row.isOutgoing, case .pending(let pending) = row.entry, pending.state == .failed,
              let openFailedMessage = actions.openFailedMessage else { return nil }
        return { openFailedMessage(pending.clientGeneratedID) }
    }
}
