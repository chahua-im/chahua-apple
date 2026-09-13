import ChahuaAPI
import Foundation

struct TimelineRowContext: Equatable {
    var isHighlighted = false
    var currentUserID: Int32?
    var isThreadTimeline = false
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
            && (openReply == nil) == (other.openReply == nil)
            && (replyToMessage == nil) == (other.replyToMessage == nil)
            && (editMessage == nil) == (other.editMessage == nil)
            && (openThread == nil) == (other.openThread == nil)
            && (openLink == nil) == (other.openLink == nil)
            && (openMention == nil) == (other.openMention == nil)
            && (openFailedMessage == nil) == (other.openFailedMessage == nil)
            && (openContextMenu == nil) == (other.openContextMenu == nil)
            && (toggleReaction == nil) == (other.toggleReaction == nil)
            && (blockPendingMessage == nil) == (other.blockPendingMessage == nil)
            && (revokePendingMessage == nil) == (other.revokePendingMessage == nil)
            && pendingReactionMessageIDs == other.pendingReactionMessageIDs
            && currentUserProfile == other.currentUserProfile
            && modifiablePendingMessageIDs == other.modifiablePendingMessageIDs
            && interactionContext == other.interactionContext
    }
}
