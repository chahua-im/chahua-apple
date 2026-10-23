import ChahuaAPI
import Foundation

/// These are overlapping views of conversations, not separate navigation stacks.
enum ConversationListScope: String, CaseIterable, Identifiable {
    case messages, groups, dms, threads

    var id: Self { self }
    var includesChats: Bool { self != .threads }
    func includesThreads(showThreadsInMessages: Bool) -> Bool {
        self == .threads || (self == .messages && showThreadsInMessages)
    }

    func summaryKey(archived: Bool, showThreadsInMessages: Bool) -> String {
        rawValue + (self == .messages && showThreadsInMessages ? "-with-threads" : "")
            + (archived ? "-archived" : "")
    }
}

struct ConversationTabBadges: Equatable {
    static var unreadViews: [ConversationView] {
        [false, true].flatMap { archived in
            ConversationListScope.allCases.map { scope in
                view(scope: scope, archived: archived, showThreadsInMessages: false)
            } + [view(scope: .messages, archived: archived, showThreadsInMessages: true)]
        }
    }

    private static func view(
        scope: ConversationListScope, archived: Bool, showThreadsInMessages: Bool
    ) -> ConversationView {
        let categories: [ConversationCategory]
        switch scope {
        case .groups: categories = [.group]
        case .dms: categories = [.dm]
        case .threads: categories = [.groupThread, .dmThread]
        case .messages:
            categories =
                [.group, .dm]
                + (showThreadsInMessages ? [.groupThread, .dmThread] : [])
        }
        return ConversationView(
            key: scope.summaryKey(
                archived: archived, showThreadsInMessages: showThreadsInMessages),
            selector: ConversationSelector(archived: archived, categories: categories))
    }

    private var summaries: [ConversationUnreadSummary]
    var archived: Bool
    var showThreadsInMessages: Bool

    init(
        summaries: [ConversationUnreadSummary] = [], archived: Bool = false,
        showThreadsInMessages: Bool = true
    ) {
        self.summaries = summaries
        self.archived = archived
        self.showThreadsInMessages = showThreadsInMessages
    }

    private func summary(for scope: ConversationListScope) -> ConversationUnreadSummary? {
        let key = scope.summaryKey(
            archived: archived, showThreadsInMessages: showThreadsInMessages)
        return summaries.first { $0.key == key }
    }

    subscript(scope: ConversationListScope) -> Int64 {
        guard let summary = summary(for: scope) else { return 0 }
        return archived ? summary.unreadConversationCount : summary.unreadUnmutedConversationCount
    }

    func attentionCount(for scope: ConversationListScope) -> Int64 {
        guard let summary = summary(for: scope) else { return 0 }
        return archived ? summary.unreadAttentionCount : summary.unreadUnmutedAttentionCount
    }

    func label(for scope: ConversationListScope) -> String? {
        if attentionCount(for: scope) > 0 { return "@" }
        let count = self[scope]
        return count > 0 ? (count > 999 ? "999+" : String(count)) : nil
    }

    func accessibilityValue(for scope: ConversationListScope) -> String {
        let attention = attentionCount(for: scope)
        if attention > 0 {
            return AppLanguage.localized("\(attention) unread mentions and replies")
        }
        let count = self[scope]
        return count > 0 ? AppLanguage.localized("\(count) unread conversations") : ""
    }
}

enum ConversationListAction: String, Equatable {
    case archive, unarchive, notificationSettings, markRead, markUnread
}

enum ConversationListItem: Hashable, Identifiable {
    case chat(ChatListItem)
    case thread(ThreadListItem)

    var id: ConversationKey {
        switch self {
        case .chat(let chat): .init(chatID: chat.id)
        case .thread(let thread):
            thread.conversationKey
        }
    }

    var title: String {
        switch self {
        case .chat(let chat):
            return chat.chatDisplayName
        case .thread(let thread):
            let preview = messagePreview(thread.threadRootMessage)
            return preview.isEmpty ? AppLanguage.localized("Message") : preview
        }
    }

    var activityDate: Date {
        switch self {
        case .chat(let chat): chat.lastMessageAt ?? .distantPast
        case .thread(let thread): thread.lastReplyAt
        }
    }

    var unreadCount: Int64 {
        switch self {
        case .chat(let chat): chat.unreadCount
        case .thread(let thread): thread.unreadCount
        }
    }

    var unreadMentions: Int64 {
        switch self {
        case .chat(let chat): chat.kind == .group ? chat.unreadMentions : 0
        case .thread(let thread): thread.chatKind == .group ? thread.unreadMentions : 0
        }
    }

    var unreadReactions: Int64 {
        switch self {
        case .chat(let chat): chat.unreadReactions
        case .thread(let thread): thread.unreadReactions
        }
    }

    func hasMutedBadges(defaults: NotificationSettingsResponse? = nil, now: Date = .now) -> Bool {
        switch self {
        case .chat(let chat): chat.archived || chat.notificationMuted(defaults: defaults, now: now)
        case .thread(let thread): thread.archived
        }
    }

    var readThroughMessageID: MessageID? {
        switch self {
        case .chat(let chat): chat.lastMessage?.id
        case .thread(let thread): thread.lastReply?.id
        }
    }

    var previewMessage: MessagePreview? {
        switch self {
        case .chat(let chat): chat.lastMessage
        case .thread(let thread): thread.lastReply ?? thread.threadRootMessage
        }
    }

    var isDirectMessage: Bool {
        switch self {
        case .chat(let chat): chat.kind == .dm
        case .thread(let thread): thread.chatKind == .dm
        }
    }

    func pendingPreview(_ pending: LocalOutgoingMessage?) -> LocalOutgoingMessage? {
        guard let pending, pending.conversationKey == id,
            pending.enqueuedAt > activityDate,
            pending.clientGeneratedID != previewMessage?.clientGeneratedId
        else { return nil }
        return pending
    }

    func deliveryStatus(
        currentUserID: Int32, hasDraft: Bool, pending: LocalOutgoingMessage?,
        readThrough: MessageID?
    ) -> MessageDeliveryStatusView.Status? {
        guard !hasDraft else { return nil }
        if let pending = pendingPreview(pending) {
            guard pending.senderID == currentUserID, pending.messageType != .system else {
                return nil
            }
            if pending.state == .failed || pending.attachments.contains(where: { $0.error != nil })
            {
                return nil
            }
            // Match the PWA list: preparation, upload, queueing and dispatch all
            // mean sending here; failures have no list delivery indicator.
            return .sending
        }
        // A topic without replies displays its root as context, not as a sent reply.
        if case .thread(let thread) = self, thread.lastReply == nil { return nil }
        guard let preview = previewMessage, preview.sender.uid == currentUserID,
            preview.messageType != .system, !preview.isDeleted
        else { return nil }
        return isDirectMessage && readThrough.map { preview.id <= $0 } == true ? .read : .sent
    }

    func previewSenderName(parentKind: ChatKind? = nil) -> String? {
        let sender: User
        switch self {
        case .chat(let chat):
            guard chat.kind == .group, let lastMessage = chat.lastMessage else { return nil }
            sender = lastMessage.sender
        case .thread(let thread):
            guard parentKind != .dm else { return nil }
            sender = (thread.lastReply ?? thread.threadRootMessage).sender
        }
        let name = sender.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name : AppLanguage.localized("User \(sender.uid)")
    }

    static func entries(
        chats: [ChatListItem], threads: [ThreadListItem], scope: ConversationListScope,
        archived: Bool = false, showThreadsInMessages: Bool = true,
        draftUpdatedAt: [ConversationKey: Date] = [:],
        pendingPreviews: [ConversationKey: LocalOutgoingMessage] = [:]
    ) -> [Self] {
        // Build the final projection buffer once and sort these large chat/thread
        // values in place, without intermediate filtered or decorated arrays.
        var result: [Self] = []
        result.reserveCapacity(
            (scope.includesChats ? chats.count : 0)
                + (scope.includesThreads(showThreadsInMessages: showThreadsInMessages)
                    ? threads.count : 0))
        if scope.includesChats {
            for chat in chats
            where chat.archived == archived
                && (scope == .messages || (scope == .groups && chat.kind == .group)
                    || (scope == .dms && chat.kind == .dm))
            {
                result.append(.chat(chat))
            }
        }
        if scope.includesThreads(showThreadsInMessages: showThreadsInMessages) {
            for thread in threads where thread.archived == archived {
                result.append(.thread(thread))
            }
        }
        result.sort {
            let lhsID = $0.id
            let rhsID = $1.id
            let lhs = max(
                $0.activityDate, draftUpdatedAt[lhsID] ?? .distantPast,
                $0.pendingPreview(pendingPreviews[lhsID])?.enqueuedAt ?? .distantPast)
            let rhs = max(
                $1.activityDate, draftUpdatedAt[rhsID] ?? .distantPast,
                $1.pendingPreview(pendingPreviews[rhsID])?.enqueuedAt ?? .distantPast)
            if lhs != rhs { return lhs > rhs }
            if lhsID.chatID != rhsID.chatID { return lhsID.chatID < rhsID.chatID }
            return (lhsID.threadID ?? "") < (rhsID.threadID ?? "")
        }
        return result
    }
}

/// View-local memoization: broad store notifications and swipe ownership changes
/// do not change list membership, ordering, or its conversation-state scope.
@MainActor
final class ConversationListSnapshotCache {
    struct Snapshot {
        var items: [ConversationListItem] = []
        var conversationRefs: [ConversationRef] = []
    }

    private struct Input: Equatable {
        let chats: [ChatListItem]
        let threads: [ThreadListItem]
        let scope: ConversationListScope
        let archived: Bool
        let showThreadsInMessages: Bool
        let draftUpdatedAt: [ConversationKey: Date]
        let pendingPreviews: [ConversationKey: LocalOutgoingMessage]
    }

    private var input: Input?
    private var cached = Snapshot()

    func snapshot(
        chats: [ChatListItem], threads: [ThreadListItem], scope: ConversationListScope,
        archived: Bool = false, showThreadsInMessages: Bool = true,
        draftUpdatedAt: [ConversationKey: Date] = [:],
        pendingPreviews: [ConversationKey: LocalOutgoingMessage] = [:]
    ) -> Snapshot {
        let trace = ScrollPerformanceTrace.begin("List.Snapshot")
        defer { ScrollPerformanceTrace.end("List.Snapshot", trace) }
        let next = Input(
            chats: scope.includesChats ? chats : [],
            threads: scope.includesThreads(showThreadsInMessages: showThreadsInMessages)
                ? threads : [],
            scope: scope, archived: archived, showThreadsInMessages: showThreadsInMessages,
            draftUpdatedAt: draftUpdatedAt, pendingPreviews: pendingPreviews)
        // Compare complete payloads, not IDs: unread counts, edits, avatars and
        // archive/mute changes must invalidate even when order stays unchanged.
        guard input != next else {
            ScrollPerformanceTrace.event("List.SnapshotHit")
            return cached
        }
        let rebuild = ScrollPerformanceTrace.begin("List.ProjectionRebuild")
        defer { ScrollPerformanceTrace.end("List.ProjectionRebuild", rebuild) }
        ScrollPerformanceTrace.event(
            "List.ProjectionInput", count: next.chats.count + next.threads.count)
        let items = ConversationListItem.entries(
            chats: next.chats, threads: next.threads, scope: scope, archived: archived,
            showThreadsInMessages: showThreadsInMessages, draftUpdatedAt: draftUpdatedAt,
            pendingPreviews: pendingPreviews)
        cached = Snapshot(
            items: items,
            conversationRefs: items.map {
                let id = $0.id
                return ConversationRef(
                    chatId: id.chatID, threadId: id.threadID.flatMap(MessageID.init))
            })
        input = next
        return cached
    }
}

extension ThreadListItem {
    /// Threads are scoped by their root message ID in its wire (decimal) form.
    var conversationKey: ConversationKey {
        .init(chatID: chatId, threadID: threadRootMessage.id.description)
    }
}

extension ChatListItem {
    var chatDisplayName: String {
        switch kind {
        case .dm:
            return nonEmpty(peer?.username) ?? nonEmpty(name)
                ?? AppLanguage.localized("Direct Message \(id)")
        case .group:
            return nonEmpty(name) ?? AppLanguage.localized("Chat \(id)")
        }
    }

    var chatAvatarURL: URL? {
        let value: String?
        switch kind {
        case .dm:
            value = peer?.avatarUrl ?? avatar
        case .group:
            value = avatar
        }
        return value.flatMap(URL.init(string:))
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
