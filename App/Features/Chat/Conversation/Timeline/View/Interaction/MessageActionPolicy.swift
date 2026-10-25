import ChahuaAPI
import Foundation

struct MessageInteractionContext: Equatable {
    var isDM = false
    var canWrite = false
    var isAdmin = false
    var isThreadView = false
    var isPinned = false
    var isUpdatingPin = false
    var isSaved = false
    var canSave = false
    var isReadOnly = false
    var speakingMode: SpeakingMode?
    var hasExistingThread = false

    var canSend: Bool {
        canSend(isThreadReply: isThreadView)
    }

    func canSend(isThreadReply: Bool) -> Bool {
        guard canWrite, !isReadOnly else { return false }
        if isDM || isAdmin { return true }
        guard let speakingMode else { return false }
        if !isThreadReply { return speakingMode.allowsMainMessages }
        return hasExistingThread
            ? speakingMode.allowsThreadReplies : speakingMode.allowsThreadCreation
    }

    var canCreateThread: Bool {
        canWrite && !isReadOnly
            && (isDM || isAdmin || speakingMode?.allowsThreadCreation == true)
    }
}

enum SpeakingWriteError: LocalizedError {
    case restricted(SpeakingMode)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .restricted(let mode): mode.restrictionExplanation
        case .unavailable:
            AppLanguage.localized("Couldn’t verify permission to send. Please try again.")
        }
    }

    var speakingRestriction: SpeakingMode? {
        if case .restricted(let mode) = self { return mode }
        return nil
    }
}

enum MessageMenuAction: String, CaseIterable, Identifiable {
    case copy, copyLink, reply, thread, pin, unpin, edit, delete, select, forward, save, favorite,
        reactionDetails

    var id: Self { self }
}

/// Hidden means inapplicable; unimplemented means relevant but intentionally disabled.
enum MessageActionAvailability: Equatable {
    case hidden, unimplemented, enabled
}

struct MessageActionPolicy {
    let messageType: MessageType
    let text: String?
    let isDeleted: Bool
    let isPending: Bool
    let hasThreadInfo: Bool
    let isOwn: Bool
    let hasReactions: Bool
    let isForwarded: Bool
    let isThreadReply: Bool
    let context: MessageInteractionContext

    init(
        messageType: MessageType,
        text: String? = nil,
        isDeleted: Bool = false,
        isPending: Bool = false,
        hasThreadInfo: Bool = false,
        isOwn: Bool = false,
        hasReactions: Bool = false,
        isForwarded: Bool = false,
        isThreadReply: Bool = false,
        context: MessageInteractionContext = .init()
    ) {
        self.messageType = messageType
        self.text = text
        self.isDeleted = isDeleted
        self.isPending = isPending
        self.hasThreadInfo = hasThreadInfo
        self.isOwn = isOwn
        self.hasReactions = hasReactions
        self.context = context
        self.isForwarded = isForwarded
        self.isThreadReply = isThreadReply
    }

    init(row: TimelineMessageRow, context: MessageInteractionContext) {
        self.init(
            messageType: row.entry.messageType,
            text: row.entry.text,
            isDeleted: row.entry.remoteMessage?.isDeleted == true,
            isPending: row.entry.remoteMessage == nil,
            hasThreadInfo: row.entry.remoteMessage?.threadInfo != nil,
            isOwn: row.isOutgoing,
            hasReactions: row.entry.remoteMessage?.reactions.contains { $0.count > 0 } == true,
            isForwarded: row.entry.presentationMessage?.forwardedFrom != nil,
            isThreadReply: row.entry.remoteMessage?.replyRootId != nil,
            context: context
        )
    }

    var actions: [MessageMenuAction] {
        let order: [MessageMenuAction] = [
            .reply, .thread, .copy, .forward, .edit, .favorite, .save, .select,
            .reactionDetails, .copyLink, context.isPinned ? .unpin : .pin, .delete,
        ]
        return order.filter { availability(of: $0) != .hidden }
    }

    var canReact: Bool {
        !context.isReadOnly && context.canWrite && !isDeleted && !isPending
            && messageType != .system && messageType != .sticker && messageType != .invite
    }

    func availability(of action: MessageMenuAction) -> MessageActionAvailability {
        if context.isReadOnly { return .hidden }
        if messageType == .sticker,
            ![MessageMenuAction.reply, .delete, .copyLink, .favorite, .select, .forward].contains(
                action)
        {
            return .hidden
        }
        if messageType == .invite,
            ![MessageMenuAction.reply, .pin, .unpin, .delete, .select].contains(action)
        {
            return .hidden
        }
        if isDeleted {
            // Preserve the PWA's history affordances, never a stale redacted body.
            switch action {
            case .reply: return context.canSend && !isPending ? .enabled : .hidden
            case .copyLink: return !context.isDM && !isPending ? .enabled : .hidden
            case .reactionDetails: return hasReactions && !isPending ? .enabled : .hidden
            default: return .hidden
            }
        }
        if isPending || messageType == .system {
            return action == .copy && hasCopyableText ? .enabled : .hidden
        }
        let applicable: Bool
        switch action {
        case .copy:
            return hasCopyableText ? .enabled : .hidden
        case .copyLink:
            return context.isDM ? .hidden : .enabled
        case .reply:
            return context.canSend ? .enabled : .hidden
        case .thread:
            return context.canCreateThread && messageType == .text && !context.isThreadView
                && !hasThreadInfo
                ? .enabled : .hidden
        case .pin:
            return context.canWrite && (context.isDM || context.isAdmin)
                && !context.isThreadView && !context.isPinned
                && !context.isUpdatingPin ? .enabled : .hidden
        case .unpin:
            return context.canWrite && (context.isDM || context.isAdmin)
                && !context.isThreadView && context.isPinned
                && !context.isUpdatingPin ? .enabled : .hidden
        case .edit:
            return context.canSend(isThreadReply: isThreadReply) && isOwn
                && messageType == .text && hasCopyableText
                && !isForwarded
                ? .enabled : .hidden
        case .delete:
            return context.canWrite && (isOwn || context.isAdmin) ? .enabled : .hidden
        case .select:
            return .enabled
        case .forward:
            return .enabled
        case .favorite:
            applicable = messageType == .sticker
        case .save:
            return messageType != .sticker && context.canSave ? .enabled : .hidden
        case .reactionDetails:
            return hasReactions ? .enabled : .hidden
        }
        return applicable ? .unimplemented : .hidden
    }

    private var hasCopyableText: Bool {
        messageType != .audio && messageType != .sticker && messageType != .invite
            && messageType != .forwarded && messageType != .placeholder
            && text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct MessageReactionEligibility {
    static let maximumPerUser = 5
    static let maximumDistinct = 50

    let canReact: Bool
    let isReacting: Bool
    let reactions: [ReactionSummary]

    var personalLimitReached: Bool {
        reactions.lazy.filter { $0.count > 0 && $0.reactedByMe == true }.count
            >= Self.maximumPerUser
    }

    var distinctLimitReached: Bool {
        reactions.lazy.filter { $0.count > 0 }.count >= Self.maximumDistinct
    }

    func isSelected(_ emoji: String) -> Bool {
        reactions.contains { $0.emoji == emoji && $0.count > 0 && $0.reactedByMe == true }
    }

    func canToggle(_ emoji: String) -> Bool {
        guard canReact, !isReacting else { return false }
        if let existing = reactions.first(where: { $0.emoji == emoji && $0.count > 0 }) {
            // Unknown realtime ownership is resolved authoritatively by the controller.
            // Keep possible removals reachable even at either limit.
            return existing.reactedByMe != false || !personalLimitReached
        }
        return !personalLimitReached && !distinctLimitReached
    }
}
