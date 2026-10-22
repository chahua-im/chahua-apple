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
    case archive, unarchive, mute, unmute, markRead, markUnread
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

    func hasMutedBadges(now: Date = .now) -> Bool {
        switch self {
        case .chat(let chat): chat.archived || chat.mutedUntil.map { $0 > now } == true
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
        draftUpdatedAt: [ConversationKey: Date] = [:]
    ) -> [Self] {
        var result: [Self] = []
        if scope.includesChats {
            result += chats.filter {
                $0.archived == archived
                    && (scope == .messages || (scope == .groups && $0.kind == .group)
                        || (scope == .dms && $0.kind == .dm))
            }.map(Self.chat)
        }
        if scope.includesThreads(showThreadsInMessages: showThreadsInMessages) {
            result += threads.filter { $0.archived == archived }.map(Self.thread)
        }
        return result.sorted {
            let lhs = max($0.activityDate, draftUpdatedAt[$0.id] ?? .distantPast)
            let rhs = max($1.activityDate, draftUpdatedAt[$1.id] ?? .distantPast)
            if lhs != rhs { return lhs > rhs }
            if $0.id.chatID != $1.id.chatID { return $0.id.chatID < $1.id.chatID }
            return ($0.id.threadID ?? "") < ($1.id.threadID ?? "")
        }
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
