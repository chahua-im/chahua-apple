#if os(iOS)
import ChahuaAPI
import SwiftUI

/// All bubble kinds consume the same cached section rectangles.
struct MessageBubble: View {
    let row: TimelineMessageRow
    let presentation: TimelineRowPresentation
    let layout: TimelineRowLayout
    let context: TimelineRowContext
    let actions: TimelineBubbleActions
    @Environment(\.colorScheme) private var colorScheme

    private var bubble: CGRect { layout.frames[.bubble] ?? .zero }
    private var sticker: Bool { row.entry.messageType == .sticker && row.entry.remoteMessage?.isDeleted != true }
    private var mediaOnly: Bool { layout.frames[.media] != nil && layout.frames[.text] == nil }
    private var filled: Bool { !sticker && (!mediaOnly || presentation.reply != nil || presentation.title != nil) }
    private var localAttachments: [LocalOutgoingAttachment] {
        if case .pending(let pending) = row.entry { return pending.attachments }
        return []
    }
    private var failureAction: (() -> Void)? {
        guard row.isOutgoing, case .pending(let pending) = row.entry, pending.state == .failed, let action = actions.openFailedMessage else { return nil }
        return { action(pending.clientGeneratedID) }
    }
    private var frames: [TimelineSectionID: CGRect] {
        layout.frames.filter { [.title, .reply, .media, .text, .metadata, .standalone].contains($0.key) }
            .mapValues { $0.offsetBy(dx: -bubble.minX, dy: -bubble.minY) }
    }

    var body: some View {
        TimelineSectionLayout(size: bubble.size, frames: frames) {
            if let frame = frames[.title], let title = presentation.title {
                MessageSenderHeader(row: row, title: title, fontSize: presentation.environment.captionSize, size: frame.size, itemFrames: layout.titleFrames)
                    .timelineSection(.title)
            }
            if let frame = frames[.reply], let preview = presentation.reply {
                MessageReplyBanner(preview: preview, isOutgoing: row.isOutgoing, hasFilledBackground: filled, openReply: actions.openReply, fontSize: presentation.environment.captionSize)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .timelineSection(.reply)
            }
            if let frame = frames[.media] {
                media(size: frame.size)
                    .frame(width: frame.width, height: frame.height)
                    .timelineSection(.media)
            }
            if let frame = frames[.text], let geometry = layout.textGeometry {
                MessageTextContent(text: row.entry.text ?? "", mentions: row.entry.remoteMessage?.mentions ?? [], currentUserID: context.currentUserID, isOutgoing: row.isOutgoing, action: actions.openLink, mentionAction: actions.openMention, metadata: frames[.media] == nil ? presentation.metadata : nil, failureAction: failureAction, geometry: geometry, fontSize: presentation.environment.bodySize)
                    .frame(width: frame.width, height: frame.height)
                    .id(row.entry.stableKey)
                    .timelineSection(.text)
            }
            if let frame = frames[.standalone] {
                Group {
                    if row.entry.remoteMessage?.isDeleted == true {
                        DeletedMessageBubble(text: presentation.standaloneText ?? "", fontSize: presentation.environment.bodySize)
                    } else {
                        UnsupportedMessageBubble(text: presentation.standaloneText ?? "", fontSize: presentation.environment.bodySize, symbolSize: layout.standaloneSymbolSize, labelGap: layout.standaloneLabelGap)
                    }
                }
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .clipped()
                .timelineSection(.standalone)
            }
            if let frame = frames[.metadata], let metadata = presentation.metadata {
                metadataView(metadata, size: frame.size)
                    .timelineSection(.metadata)
            }
        }
        .foregroundStyle(row.isOutgoing && filled ? ChahuaTheme.ChatBubble.outgoingForeground : ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme))
        .modifier(MessageBubbleSurface(isOutgoing: row.isOutgoing, hasTail: !sticker && !mediaOnly && (row.groupPosition == .single || row.groupPosition == .last), isFilled: filled))
    }

    @ViewBuilder
    private func media(size: CGSize) -> some View {
        if sticker {
            StickerContent(sticker: row.entry.remoteMessage?.sticker, size: size)
        } else if !localAttachments.isEmpty {
            BubbleLocalMedia(attachments: localAttachments, size: size, itemFrames: layout.mediaFrames)
        } else {
            BubbleMedia(messageID: row.entry.remoteMessage?.id ?? "", attachments: row.entry.remoteMessage?.attachments ?? [], size: size, itemFrames: layout.mediaFrames, action: actions.openMedia)
        }
    }

    private func metadataView(_ metadata: MessageMetadata, size: CGSize) -> some View {
        let overlay = presentation.metadataIsOverlay && frames[.media] != nil
        let padding = overlay ? min(6, size.width / 2) : 0
        let width = max(0, size.width - 2 * padding)
        let scale = metadata.size.width > 0 ? min(1, width / metadata.size.width) : 1
        return MessageMetadataView(metadata: metadata, failureAction: failureAction)
            .scaleEffect(scale, anchor: .center)
            .frame(width: size.width, height: size.height)
            .background(overlay ? Color.black.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
}


#endif
