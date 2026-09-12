import ChahuaAPI
import SwiftUI

/// Text messages may carry images, but never own row accessories or other message kinds.
struct TextMessageBubble: View {
    let row: TimelineMessageRow
    let context: TimelineRowContext
    let actions: TimelineBubbleActions
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var metadataSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var overlayMetadataSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = BubbleMetrics.avatarSize

    private var message: MessageResponse? { row.entry.remoteMessage }
    private var attachments: [AttachmentResponse] { message?.attachments ?? [] }
    private var localAttachments: [LocalOutgoingAttachment] {
        guard case .pending(let pending) = row.entry else { return [] }
        return pending.attachments
    }
    private var bodyText: String { row.entry.text ?? "" }
    private var hasBody: Bool { !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasMedia: Bool { !attachments.isEmpty || !localAttachments.isEmpty }
    private var mediaOnly: Bool { hasMedia && !hasBody }
    private var replyPreview: MessagePreview? {
        guard let preview = row.entry.replyToMessage, !preview.isDeleted else { return nil }
        return preview
    }
    private var threadCount: Int64? { context.isThreadTimeline ? nil : message?.threadInfo?.replyCount }
    private var hasBackground: Bool { !mediaOnly || row.showsSenderName || replyPreview != nil || threadCount != nil }
    private var hasTail: Bool { !mediaOnly && (row.groupPosition == .single || row.groupPosition == .last) }
    private var foreground: Color {
        row.isOutgoing && hasBackground ? ChahuaTheme.ChatBubble.outgoingForeground : ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme)
    }
    private var availableMediaWidth: CGFloat {
        BubbleMetrics.maximumBubbleWidth(rowWidth: context.viewportSize.width, avatarSize: avatarSize)
    }
    private var mediaSize: CGSize? {
        if !localAttachments.isEmpty {
            return BubbleMediaLayout.size(for: localAttachments, viewport: context.viewportSize, availableWidth: availableMediaWidth)
        }
        return BubbleMediaLayout.size(for: attachments, viewport: context.viewportSize, availableWidth: availableMediaWidth)
    }

    var body: some View {
        let mediaSize = mediaSize
        BubbleColumnLayout {
            if row.showsSenderName {
                MessageSenderHeader(row: row, currentUserProfile: actions.currentUserProfile, usesOutgoingForeground: row.isOutgoing && hasBackground)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            if let preview = replyPreview {
                MessageReplyBanner(preview: preview, isOutgoing: row.isOutgoing, hasFilledBackground: hasBackground, openReply: actions.openReply)
                    .padding(.horizontal, 12)
                    .padding(.top, row.showsSenderName ? 0 : 8)
                    .padding(.bottom, 6)
            }
            if let mediaSize, mediaSize.width > 0, mediaSize.height > 0 {
                Group {
                    if !localAttachments.isEmpty {
                        BubbleLocalMedia(
                            attachments: localAttachments, viewport: context.viewportSize,
                            availableWidth: availableMediaWidth, isMeasuring: context.isMeasuring
                        )
                    } else {
                        BubbleMedia(
                            messageID: message?.id ?? "", attachments: attachments,
                            viewport: context.viewportSize, availableWidth: availableMediaWidth,
                            isMeasuring: context.isMeasuring, action: actions.openMedia
                        )
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if mediaOnly {
                        MessageMetadataView(
                            metadata: MessageMetadata(row: row, isOverlay: true, fontSize: overlayMetadataSize),
                            failureAction: failureAction
                        )
                        .frame(maxWidth: max(1, mediaSize.width - 24))
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        .padding(6)
                    }
                }
                .padding(.top, row.showsSenderName || replyPreview != nil ? 4 : 0)
            }
            if !mediaOnly {
                textContent
                    .padding(.horizontal, BubbleMetrics.textHorizontalInset)
                    .padding(.top, hasMedia ? 4 : (row.showsSenderName || replyPreview != nil ? 0 : BubbleMetrics.textVerticalInset))
                    .padding(.bottom, threadCount == nil ? BubbleMetrics.textVerticalInset : 0)
            }
            if let count = threadCount {
                MessageThreadIndicator(
                    count: count, isOutgoing: row.isOutgoing, showsSeparator: !mediaOnly,
                    action: message.flatMap { message in actions.openThread.map { action in { action(message.id) } } }
                )
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
        .frame(width: mediaSize?.width)
        .foregroundStyle(foreground)
        .modifier(MessageBubbleSurface(isOutgoing: row.isOutgoing, hasTail: hasTail, isFilled: hasBackground))
    }

    private var failureAction: (() -> Void)? {
        guard row.isOutgoing, case .pending(let pending) = row.entry, pending.state == .failed,
              let openFailedMessage = actions.openFailedMessage else { return nil }
        return { openFailedMessage(pending.clientGeneratedID) }
    }

    @ViewBuilder private var textContent: some View {
        let metadata = MessageMetadata(row: row, fontSize: metadataSize)
        if hasBody {
            MessageTextContent(
                text: bodyText, mentions: message?.mentions ?? [], currentUserID: context.currentUserID,
                isOutgoing: row.isOutgoing, action: actions.openLink, mentionAction: actions.openMention,
                metadata: metadata, failureAction: failureAction
            )
        } else {
            MessageMetadataView(metadata: metadata, failureAction: failureAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
