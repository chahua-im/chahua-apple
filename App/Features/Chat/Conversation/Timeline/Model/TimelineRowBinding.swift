import ChahuaAPI
import Foundation

struct TimelineRowContext: Equatable {
    var isHighlighted = false
    var currentUserID: Int32?
    var isThreadTimeline = false
    var isInteractionPreview = false
}

/// Captured from the native row before presentation. Its prepared layout and
/// typography remain authoritative; an overlay must never infer a timeline width
/// from the already-measured bubble width.
struct MessageInteractionSource {
    let rect: CGRect
    let presentation: TimelineRowPresentation
    let layout: TimelineRowLayout
    #if os(iOS)
        var pressFeedback: MessageBubblePressFeedback? = nil
    #endif
}

struct TimelineBubbleActions {
    var openMedia: ((MessageImageGallery) -> Void)?
    var openSticker: ((String) -> Void)?
    var openReply: ((MessageID) -> Void)?
    var openReactionDetails: ((MessageResponse) -> Void)?
    var replyToMessage: ((MessageResponse) -> Void)?
    var editMessage: ((MessageResponse) -> Void)?
    var togglePin: ((MessageResponse) -> Void)?
    var pinnedMessageIDs: Set<MessageID> = []
    var pendingPinMessageIDs: Set<MessageID> = []
    var deleteMessage: ((MessageResponse) -> Void)?
    var openThread: ((MessageID) -> Void)?
    var openLink: ((URL) -> Void)?
    var openMention: ((Int32) -> Void)?
    var openFailedMessage: ((String) -> Void)?
    var openContextMenu: ((TimelineMessageRow, MessageInteractionSource) -> Void)?
    var toggleReaction: ((TimelineMessageRow, String) -> Void)?
    var pendingReactionMessageIDs: Set<MessageID> = []
    var interactionContext = MessageInteractionContext()
    var modifiablePendingMessageIDs: Set<String> = []
    var blockPendingMessage: ((PendingOutgoingMessage) -> Void)?
    var revokePendingMessage: ((PendingOutgoingMessage) -> Void)?
    var isSelectingMessages = false
    var selectedMessageIDs: Set<MessageID> = []
    var toggleMessageSelection: ((MessageResponse) -> Void)?
    var endMessageSelection: (() -> Void)?
    var forwardMessage: ((MessageResponse) -> Void)?
    var openForwardedMessages: ((MessageResponse) -> Void)?
    var isSelectionBusy = false
    var selectionMessages: [MessageResponse] = []
    var removeSelectedMessage: ((MessageID) -> Void)?
    var openAttachment: ((AttachmentResponse) -> Void)?
}

struct TimelineRowBinding {
    let presentation: TimelineRowPresentation
    let layout: TimelineRowLayout
    let context: TimelineRowContext
    let actions: TimelineBubbleActions
    let mediaContext: AppMediaContext?

    func hasSameRendering(as other: Self) -> Bool {
        presentation.row == other.presentation.row
            && presentation.layoutKey == other.presentation.layoutKey
            && presentation.environment == other.presentation.environment
            && context == other.context
            && mediaContext === other.mediaContext
            && actions.hasSameRendering(as: other.actions)
    }
}

extension TimelineBubbleActions {
    func hasSameRendering(as other: Self) -> Bool {
        (openMedia == nil) == (other.openMedia == nil)
            && (openSticker == nil) == (other.openSticker == nil)
            && (openReply == nil) == (other.openReply == nil)
            && (openReactionDetails == nil) == (other.openReactionDetails == nil)
            && (replyToMessage == nil) == (other.replyToMessage == nil)
            && (editMessage == nil) == (other.editMessage == nil)
            && (togglePin == nil) == (other.togglePin == nil)
            && pinnedMessageIDs == other.pinnedMessageIDs
            && pendingPinMessageIDs == other.pendingPinMessageIDs
            && (deleteMessage == nil) == (other.deleteMessage == nil)
            && (openThread == nil) == (other.openThread == nil)
            && (openLink == nil) == (other.openLink == nil)
            && (openMention == nil) == (other.openMention == nil)
            && (openFailedMessage == nil) == (other.openFailedMessage == nil)
            && (openContextMenu == nil) == (other.openContextMenu == nil)
            && (toggleReaction == nil) == (other.toggleReaction == nil)
            && (blockPendingMessage == nil) == (other.blockPendingMessage == nil)
            && (revokePendingMessage == nil) == (other.revokePendingMessage == nil)
            && pendingReactionMessageIDs == other.pendingReactionMessageIDs
            && modifiablePendingMessageIDs == other.modifiablePendingMessageIDs
            && interactionContext == other.interactionContext
            && isSelectingMessages == other.isSelectingMessages
            && selectedMessageIDs == other.selectedMessageIDs
            && (toggleMessageSelection == nil) == (other.toggleMessageSelection == nil)
            && (endMessageSelection == nil) == (other.endMessageSelection == nil)
            && (forwardMessage == nil) == (other.forwardMessage == nil)
            && (openForwardedMessages == nil) == (other.openForwardedMessages == nil)
            && isSelectionBusy == other.isSelectionBusy
            && (removeSelectedMessage == nil) == (other.removeSelectedMessage == nil)
            && (openAttachment == nil) == (other.openAttachment == nil)
    }

    func pinContext(for row: TimelineMessageRow, base: MessageInteractionContext)
        -> MessageInteractionContext
    {
        var result = base
        let id = row.entry.serverID
        result.isPinned = id.map(pinnedMessageIDs.contains) ?? false
        result.isUpdatingPin = togglePin == nil || (id.map(pendingPinMessageIDs.contains) ?? false)
        return result
    }

    /// Pending sends have no server ID and cannot have a reaction request in flight.
    func isReacting(to entry: ConversationTimelineEntry) -> Bool {
        entry.serverID.map(pendingReactionMessageIDs.contains) ?? false
    }
}
