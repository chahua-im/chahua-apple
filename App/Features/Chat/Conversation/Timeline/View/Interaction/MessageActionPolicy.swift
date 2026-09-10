import ChahuaAPI
import Foundation

struct MessageInteractionContext: Equatable {
    var isDM = false
    var canWrite = false
    var isAdmin = false
    var isThreadView = false
    var isPinned = false
}

enum MessageMenuAction: String, CaseIterable, Identifiable {
    case copy, copyLink, reply, thread, pin, unpin, edit, delete, save, favorite, reactionDetails

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
    let context: MessageInteractionContext

    init(
        messageType: MessageType,
        text: String? = nil,
        isDeleted: Bool = false,
        isPending: Bool = false,
        hasThreadInfo: Bool = false,
        isOwn: Bool = false,
        hasReactions: Bool = false,
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
            context: context
        )
    }

    var actions: [MessageMenuAction] {
        let order: [MessageMenuAction] = [
            .reply, .thread, context.isPinned ? .unpin : .pin, .copy, .edit,
            .favorite, .save, .copyLink, .delete, .reactionDetails,
        ]
        return order.filter { availability(of: $0) != .hidden }
    }

    var canReact: Bool {
        context.canWrite && !isDeleted && !isPending
            && messageType != .system && messageType != .sticker && messageType != .invite
    }

    func availability(of action: MessageMenuAction) -> MessageActionAvailability {
        if messageType == .sticker,
            ![MessageMenuAction.reply, .delete, .copyLink, .favorite].contains(action)
        {
            return .hidden
        }
        if messageType == .invite,
            ![MessageMenuAction.reply, .pin, .unpin, .delete].contains(action)
        {
            return .hidden
        }
        if isDeleted {
            // Preserve the PWA's history affordances, never a stale redacted body.
            switch action {
            case .reply: return context.canWrite && !isPending ? .enabled : .hidden
            case .copyLink: return context.isDM ? .hidden : .unimplemented
            case .reactionDetails: return hasReactions ? .unimplemented : .hidden
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
            applicable = !context.isDM
        case .reply:
            return context.canWrite ? .enabled : .hidden
        case .thread:
            applicable = context.canWrite && messageType == .text && !context.isThreadView && !hasThreadInfo
        case .pin:
            applicable = context.canWrite && context.isAdmin && !context.isPinned
        case .unpin:
            applicable = context.canWrite && context.isAdmin && context.isPinned
        case .edit:
            applicable =
                context.canWrite && isOwn && messageType != .audio
                && messageType != .sticker && messageType != .file
        case .delete:
            applicable = context.canWrite && (isOwn || context.isAdmin)
        case .favorite:
            applicable = messageType == .sticker
        case .save:
            applicable = messageType != .sticker
        case .reactionDetails:
            applicable = hasReactions
        }
        return applicable ? .unimplemented : .hidden
    }

    private var hasCopyableText: Bool {
        messageType != .audio && messageType != .sticker && messageType != .invite
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
        reactions.lazy.filter { $0.count > 0 && $0.reactedByMe == true }.count >= Self.maximumPerUser
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
