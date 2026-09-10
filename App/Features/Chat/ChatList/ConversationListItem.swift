import ChahuaAPI
import Foundation

/// These are overlapping views of conversations, not separate navigation stacks.
enum ConversationListScope: String, CaseIterable, Identifiable {
    case messages, groups, dms, threads

    var id: Self { self }
    var includesChats: Bool { self != .threads }
    var includesThreads: Bool { self == .messages || self == .threads }
}

enum ConversationListItem: Hashable, Identifiable {
    case chat(ChatListItem)
    case thread(ThreadListItem)

    var id: ConversationKey {
        switch self {
        case .chat(let chat): .init(chatID: chat.id)
        case .thread(let thread): .init(chatID: thread.chatId, threadID: thread.threadRootMessage.id)
        }
    }

    var title: String {
        switch self {
        case .chat(let chat): chat.chatDisplayName
        case .thread(let thread): thread.threadRootMessage.conversationPreview
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

    var preview: String? {
        switch self {
        case .chat(let chat): chat.lastMessage?.conversationPreview
        case .thread(let thread): thread.chatName
        }
    }

    static func entries(chats: [ChatListItem], threads: [ThreadListItem], scope: ConversationListScope, draftUpdatedAt: [ConversationKey: Date] = [:]) -> [Self] {
        var result: [Self] = []
        if scope.includesChats {
            result += chats.filter {
                !$0.archived && (scope == .messages || (scope == .groups && $0.kind == .group) || (scope == .dms && $0.kind == .dm))
            }.map(Self.chat)
        }
        if scope.includesThreads {
            result += threads.filter { !$0.archived }.map(Self.thread)
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

extension MessagePreview {
    var conversationPreview: String {
        if isDeleted { return String(localized: "Message deleted") }
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return message }
        if let sticker { return sticker.emoji }
        if !attachments.isEmpty { return String(localized: "Attachment") }
        return String(localized: "Message")
    }
}
extension ChatListItem {
    var chatDisplayName: String {
        switch kind {
        case .dm:
            return nonEmpty(peer?.username) ?? nonEmpty(name) ?? String(localized: "Direct Message \(id)")
        case .group:
            return nonEmpty(name) ?? String(localized: "Chat \(id)")
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
