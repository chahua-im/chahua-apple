import ChahuaAPI
import SwiftUI

struct ConversationListRow: View {
    let item: ConversationListItem
    let draft: String
    var pending: LocalOutgoingMessage? = nil
    // Presence and receipt changes are observed by their small child views.
    let store: ChatStore
    let currentUserID: Int32
    let isSelected: Bool
    var badgeColor = ConversationListPreferences.defaultUnreadBadgeColor
    @Environment(\.isWideChatLayout) private var isWideChatLayout
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var subtitleHeight: CGFloat = 19

    // Row creation and minute ticks must not rebuild Foundation's formatter.
    // View rendering serializes access on the main actor, including locale changes.
    @MainActor private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    private var usesDesktopDensity: Bool {
        ConversationListMetrics.usesDesktopDensity(isWide: isWideChatLayout)
    }

    private var previewFontSize: CGFloat { usesDesktopDensity ? 13 : 17 }

    private var titleLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: ChahuaTheme.Spacing.medium))
    }

    private var isMuted: Bool {
        guard case .chat(let chat) = item else { return false }
        return chat.notificationMuted(defaults: store.state.notificationDefaults)
    }

    private var usesMutedBadges: Bool {
        item.hasMutedBadges(defaults: store.state.notificationDefaults)
    }

    private var threadParentKind: ChatKind? {
        guard case .thread(let thread) = item else { return nil }
        return thread.chatKind
    }

    var body: some View {
        let pendingPreview = item.pendingPreview(pending)
        HStack(
            alignment: .center,
            spacing: usesDesktopDensity ? 10 : (isWideChatLayout ? 8 : ChahuaTheme.Spacing.medium)
        ) {
            ConversationAvatarView(
                item: item, store: store, currentUserID: currentUserID,
                diameter: ConversationListMetrics.avatarDiameter(isWide: isWideChatLayout),
                isSelected: isSelected)
            VStack(alignment: .leading, spacing: usesDesktopDensity ? 3 : 4) {
                titleLayout {
                    Group {
                        if case .thread(let thread) = item {
                            MessageSummaryText(
                                thread.threadRootMessage, fontSize: usesDesktopDensity ? 14 : 17,
                                color: isSelected ? .white : .primary, weight: .semibold,
                                fallback: AppLanguage.localized("Message"))
                        } else {
                            Text(item.title)
                                .font(
                                    usesDesktopDensity
                                        ? .system(size: 14, weight: .semibold) : .headline
                                )
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        ConversationListDeliveryIndicator(
                            item: item, hasDraft: !draft.isEmpty, pending: pendingPreview,
                            currentUserID: currentUserID, receipts: store.listReadReceipts)
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(activityLabel(now: context.date))
                                .font(usesDesktopDensity ? .system(size: 11) : .footnote)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        }
                    }
                    .foregroundStyle(
                        isSelected
                            ? Color.white.opacity(usesDesktopDensity ? 0.88 : 0.8)
                            : (usesDesktopDensity ? Color.secondary : Color.primary)
                    )
                    .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                }
                HStack(spacing: ChahuaTheme.Spacing.medium) {
                    Group {
                        if !draft.isEmpty {
                            MessageSummaryText(
                                source: draft, fontSize: previewFontSize, color: subtitleColor,
                                prefix: AppLanguage.localized("Draft") + ": ")
                        } else if let pendingPreview {
                            MessageSummaryText(
                                pending: pendingPreview, fontSize: previewFontSize,
                                color: subtitleColor,
                                prefix: item.isDirectMessage
                                    ? ""
                                    : (store.currentUserProfile?.asSender.name
                                        ?? AppLanguage.localized("User \(currentUserID)")) + ": ")
                        } else if let preview = item.previewMessage {
                            MessageSummaryText(
                                preview, fontSize: previewFontSize, color: subtitleColor,
                                prefix: item.previewSenderName(parentKind: threadParentKind)
                                    .map { $0 + ": " } ?? "",
                                boldPrefix: true, fallback: AppLanguage.localized("Message"))
                        } else {
                            Color.clear
                        }
                    }
                    .modifier(ConversationListSubtitleStyle(isSelected: isSelected))
                    if item.unreadMentions > 0 {
                        activityBadge {
                            Text("@")
                        }
                        .accessibilityLabel("Unread mentions and replies")
                    }
                    if item.unreadReactions > 0 {
                        activityBadge {
                            Image(systemName: "heart.fill")
                        }
                        .accessibilityLabel("Unread reactions")
                    }
                    if item.unreadCount > 0 {
                        activityBadge {
                            Text(item.unreadCount > 99 ? "99+" : String(item.unreadCount))
                        }
                        .accessibilityLabel("\(item.unreadCount) unread messages")
                    } else if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.footnote)
                            .foregroundStyle(
                                isSelected ? Color.white.opacity(0.88) : Color.secondary
                            )
                            .frame(minWidth: 24)
                            .accessibilityLabel("Muted")
                    }
                }
                .frame(minHeight: usesDesktopDensity ? 16 : subtitleHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(ConversationListRowLayout())
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }

    private var subtitleColor: Color {
        isSelected ? Color.white.opacity(0.88) : .secondary
    }

    private func activityBadge<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(
                usesDesktopDensity
                    ? .system(size: 11, weight: .semibold) : .caption.weight(.semibold)
            )
            .foregroundStyle(usesMutedBadges ? Color.primary : Color.white)
            .padding(.horizontal, usesDesktopDensity ? 5 : 8)
            .padding(.vertical, 2)
            .frame(minHeight: usesDesktopDensity ? 18 : nil)
            .background {
                if usesMutedBadges {
                    Capsule().fill(.quaternary)
                } else {
                    Capsule().fill(badgeColor.color)
                }
            }
            .fixedSize()
    }

    @MainActor private func activityLabel(now: Date) -> String {
        let date = max(item.activityDate, item.pendingPreview(pending)?.enqueuedAt ?? .distantPast)
        guard date != .distantPast else { return "" }
        if calendar.isDate(date, inSameDayAs: now) {
            let minutes = max(1, Int(now.timeIntervalSince(date) / 60))
            let formatter = Self.relativeTimeFormatter
            if formatter.locale != locale { formatter.locale = locale }
            return formatter.localizedString(
                from: minutes < 60
                    ? DateComponents(minute: -minutes) : DateComponents(hour: -(minutes / 60)))
        }
        let format = Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()
        return date.formatted(
            calendar.component(.year, from: date) == calendar.component(.year, from: now)
                ? format : format.year())
    }

}

private struct ConversationListDeliveryIndicator: View {
    let item: ConversationListItem
    let hasDraft: Bool
    let pending: LocalOutgoingMessage?
    let currentUserID: Int32
    @ObservedObject var receipts: ConversationListReadReceipts

    var body: some View {
        if let status = item.deliveryStatus(
            currentUserID: currentUserID, hasDraft: hasDraft, pending: pending,
            readThrough: receipts.values[item.id])
        {
            MessageDeliveryStatusView(status: status, size: 12)
        }
    }
}

/// Keep archive and conversation rows aligned without clipping scaled content.
struct ConversationListRowLayout: ViewModifier {
    @Environment(\.isWideChatLayout) private var isWideChatLayout

    func body(content: Content) -> some View {
        let desktop = ConversationListMetrics.usesDesktopDensity(isWide: isWideChatLayout)
        content
            .padding(
                .horizontal, desktop ? 10 : (isWideChatLayout ? 8 : ChatSplitMetrics.outerInset)
            )
            .padding(.vertical, 10)
            .frame(minHeight: desktop ? 60 : 68)
    }
}

/// The archived entry and conversation rows use the same secondary line
/// typography even though their navigation and trailing metadata differ.
struct ConversationListSubtitleStyle: ViewModifier {
    let isSelected: Bool
    @Environment(\.isWideChatLayout) private var isWideChatLayout

    func body(content: Content) -> some View {
        content
            .font(
                ConversationListMetrics.usesDesktopDensity(isWide: isWideChatLayout)
                    ? .system(size: 13) : .body
            )
            .foregroundStyle(isSelected ? Color.white.opacity(0.88) : Color.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ConversationListMetrics {
    // Pointer-driven macOS sidebars use the reference's denser typography and
    // 40-point avatars; wide iPad sidebars retain iPhone-sized touch targets.
    static func usesDesktopDensity(isWide: Bool) -> Bool {
        #if os(macOS)
            isWide
        #else
            false
        #endif
    }

    static func avatarDiameter(isWide: Bool) -> CGFloat {
        usesDesktopDensity(isWide: isWide) ? 40 : 48
    }
}

#if DEBUG
    #Preview("Conversation rows") {
        ConversationListRowPreview()
    }

    struct ConversationListRowPreview: View {
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
            let message = try! decoder.decode(
                MessagePreview.self,
                from: Data(
                    """
                    {
                        "id": "1", "clientGeneratedId": "preview-client",
                        "createdAt": "2026-09-10T08:00:00Z",
                        "sender": {"uid": 2, "gender": 0, "name": "Ada"},
                        "messageType": "text", "message": "Hi @[uid:2], the latest designs are ready for review.",
                        "attachments": [], "mentions": [{"uid": 2, "gender": 0, "username": "Grace"}], "isDeleted": false
                    }
                    """.utf8))
            let outgoing = MessagePreview(
                id: MessageID(2), clientGeneratedId: "outgoing-preview",
                createdAt: message.createdAt,
                sender: User(uid: 1, gender: 0, name: "You", avatarUrl: nil, userGroup: nil),
                messageType: .text, message: "The latest designs are ready for review.")

            func chat(
                _ id: String, name: String, kind: ChatKind = .group, unread: Int64 = 0,
                muted: Bool = false, preview: MessagePreview? = nil
            ) -> ConversationListItem {
                let preview = preview ?? message
                return .chat(
                    ChatListItem(
                        id: id, name: name, lastMessageAt: preview.createdAt,
                        unreadCount: unread, lastMessage: preview,
                        mutedUntil: muted ? .distantFuture : nil, archived: false, kind: kind,
                        peer: kind == .dm ? MemberSummary(uid: 2, username: name, gender: 0) : nil))
            }

            func thread(_ id: String, unread: Int64) -> ConversationListItem {
                .thread(
                    ThreadListItem(
                        chatId: id, chatName: "Design team", threadRootMessage: message,
                        participants: [message.sender], lastReply: message, replyCount: 8,
                        lastReplyAt: message.createdAt, unreadCount: unread,
                        chatKind: .group, subscribedAt: message.createdAt, archived: false))
            }

            examples = [
                (
                    "Outgoing · sent",
                    chat("outgoing-sent", name: "Single check", kind: .dm, preview: outgoing), ""
                ),
                (
                    "Outgoing · read",
                    chat("outgoing-read", name: "Double check", kind: .dm, preview: outgoing), ""
                ),
                (
                    "Outgoing · group",
                    chat("outgoing-group", name: "Group stays single", preview: outgoing), ""
                ),
                (
                    "Outgoing · draft",
                    chat("outgoing-draft", name: "Draft hides check", kind: .dm, preview: outgoing),
                    "Not sent yet"
                ),
                ("Group · unread", chat("group-unread", name: "Design team", unread: 3), ""),
                ("Group · read", chat("group-read", name: "Weekend plans"), ""),
                ("DM · unread", chat("dm-unread", name: "Ada Lovelace", kind: .dm, unread: 2), ""),
                ("DM · read", chat("dm-read", name: "Grace Hopper", kind: .dm), ""),
                ("Thread · unread", thread("thread-unread", unread: 4), ""),
                ("Thread · read", thread("thread-read", unread: 0), ""),
                (
                    "Muted · unread",
                    chat("muted-unread", name: "Announcements", unread: 12, muted: true), ""
                ),
                ("Muted · read", chat("muted-read", name: "Community", muted: true), ""),
                ("Unread · 99+", chat("many-unread", name: "General", unread: 154), ""),
                ("Draft", chat("draft", name: "Design team"), "Let's review the latest updates."),
            ]
            let version = store.listReadReceipts.snapshot()
            for id in ["outgoing-read", "outgoing-group", "outgoing-draft"] {
                store.listReadReceipts.accept(outgoing.id, for: .init(chatID: id), version: version)
            }
        }

        var body: some View {
            List {
                ForEach(examples.indices, id: \.self) { index in
                    let example = examples[index]
                    ConversationListRow(
                        item: example.item, draft: example.draft,
                        store: store, currentUserID: 1, isSelected: index == 0
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(index == 0 ? ChahuaTheme.ChatList.primary : Color.clear)
                }
            }
            .safeAreaPadding()
            .listStyle(.plain)
            .frame(width: 400, height: 900)
        }
    }
#endif
