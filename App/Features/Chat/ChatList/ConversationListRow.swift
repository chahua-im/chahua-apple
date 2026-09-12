import ChahuaAPI
import SwiftUI

struct ConversationListRow: View {
    let item: ConversationListItem
    let draft: String
    @ObservedObject var store: ChatStore
    let currentUserID: Int32
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    private var isMuted: Bool {
        guard case .chat(let chat) = item, let until = chat.mutedUntil else { return false }
        return until > .now
    }

    var body: some View {
        HStack(alignment: .center, spacing: ChahuaTheme.Spacing.medium) {
            ConversationAvatarView(
                item: item, store: store, currentUserID: currentUserID,
                diameter: 48, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: ChahuaTheme.Spacing.medium) {
                    Text(item.title).font(.headline).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(activityLabel(now: context.date))
                            .font(.system(size: 13))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.primary)
                            .lineLimit(1)
                    }
                    .fixedSize()
                }
                HStack(spacing: ChahuaTheme.Spacing.medium) {
                    Group {
                        if !draft.isEmpty {
                            Text("Draft: \(draft)")
                        } else if let preview = item.preview {
                            Text(preview)
                        } else {
                            Color.clear
                        }
                    }
                    .foregroundStyle(isSelected ? Color.white.opacity(0.88) : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if item.unreadCount > 0 {
                        Text(item.unreadCount > 99 ? "99+" : String(item.unreadCount))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(isMuted ? ChahuaTheme.ChatList.muted(for: colorScheme) : ChahuaTheme.ChatList.primary, in: Capsule())
                            .fixedSize()
                            .accessibilityLabel("\(item.unreadCount) unread messages")
                    }
                }
                .frame(height: 19)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(height: 60)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }

    private func activityLabel(now: Date) -> String {
        let date = item.activityDate
        guard date != .distantPast else { return "" }
        if calendar.isDate(date, inSameDayAs: now) {
            let minutes = max(1, Int(now.timeIntervalSince(date) / 60))
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .numeric
            return formatter.localizedString(from: minutes < 60
                ? DateComponents(minute: -minutes) : DateComponents(hour: -(minutes / 60)))
        }
        let format = Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()
        return date.formatted(calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? format : format.year())
    }

}

#if DEBUG
#Preview("Conversation rows") {
    ConversationListRowPreview()
}

private struct ConversationListRowPreview: View {
    private let store: ChatStore
    private let examples: [(label: String, item: ConversationListItem, draft: String)]

    init() {
        let client = FixtureReactionClient()
        let queue = OutgoingMessageQueue(
            apiClient: client,
            localStoreFactory: { _ in throw CancellationError() },
            onInvalidToken: {})
        store = ChatStore(apiClient: client, outgoingQueue: queue, onInvalidToken: {})

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try! decoder.decode(MessagePreview.self, from: Data("""
            {
                "id": "preview-root", "clientGeneratedId": "preview-client",
                "createdAt": "2026-09-10T08:00:00Z",
                "sender": {"uid": 2, "gender": 0, "name": "Ada"},
                "messageType": "text", "message": "The latest designs are ready for review.",
                "attachments": [], "mentions": [], "isDeleted": false
            }
            """.utf8))

        func chat(_ id: String, name: String, kind: ChatKind = .group, unread: Int64 = 0, muted: Bool = false) -> ConversationListItem {
            .chat(ChatListItem(
                id: id, name: name, lastMessageAt: message.createdAt,
                unreadCount: unread, lastMessage: message,
                mutedUntil: muted ? .distantFuture : nil, archived: false, kind: kind,
                peer: kind == .dm ? MemberSummary(uid: 2, username: name, gender: 0) : nil))
        }

        func thread(_ id: String, unread: Int64) -> ConversationListItem {
            .thread(ThreadListItem(
                chatId: id, chatName: "Design team", threadRootMessage: message,
                participants: [message.sender], lastReply: message, replyCount: 8,
                lastReplyAt: message.createdAt, unreadCount: unread,
                subscribedAt: message.createdAt, archived: false))
        }

        examples = [
            ("Group · unread", chat("group-unread", name: "Design team", unread: 3), ""),
            ("Group · read", chat("group-read", name: "Weekend plans"), ""),
            ("DM · unread", chat("dm-unread", name: "Ada Lovelace", kind: .dm, unread: 2), ""),
            ("DM · read", chat("dm-read", name: "Grace Hopper", kind: .dm), ""),
            ("Thread · unread", thread("thread-unread", unread: 4), ""),
            ("Thread · read", thread("thread-read", unread: 0), ""),
            ("Muted · unread", chat("muted-unread", name: "Announcements", unread: 12, muted: true), ""),
            ("Muted · read", chat("muted-read", name: "Community", muted: true), ""),
            ("Unread · 99+", chat("many-unread", name: "General", unread: 154), ""),
            ("Draft", chat("draft", name: "Design team"), "Let's review the latest updates."),
        ]
    }

    var body: some View {
        List {
            ForEach(examples.indices, id: \.self) { index in
                let example = examples[index]
                Section(example.label) {
                    ConversationListRow(
                        item: example.item, draft: example.draft,
                        store: store, currentUserID: 1, isSelected: index == 0)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(index == 0 ? ChahuaTheme.ChatList.primary : Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .frame(width: 400, height: 900)
    }
}
#endif
