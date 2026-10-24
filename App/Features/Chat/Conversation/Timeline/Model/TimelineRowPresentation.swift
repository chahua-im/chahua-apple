import ChahuaAPI
import ChahuaMarkdown
import SwiftUI

struct TitleContent: Hashable {
    let name: String
    let userGroup: UserGroupTagInfo?
    let genderGlyph: String?

    var groupName: String? { userGroup?.name.flatMap { $0.isEmpty ? nil : $0 } }
}

enum RowSectionKey: Hashable {
    case kind(String)
    case grouping(outgoing: Bool, position: TimelineGroupPosition, title: Bool, avatar: Bool)
    case title(TitleContent?)
    case body(String, mentionLabels: [String])
    case reply(MessagePreview)
    case media([CGSize], category: String)
    case audio
    case sticker(CGSize)
    case metadata(CGSize, overlay: Bool)
    case reaction(emoji: String, count: Int64, reactors: Int)
    case thread(String)
    case standalone(String, author: String?)
}

struct RowLayoutKey: Hashable {
    let sections: [RowSectionKey]
}

struct TimelineRowPresentation {
    let row: TimelineRow
    let environment: TimelineLayoutEnvironment
    let title: TitleContent?
    let reply: MessagePreview?
    let originLabel: String?
    let originalReply: MessagePreview?
    let forwardedCardLines: [String]
    let markdown: MarkdownDocument?
    let metadata: MessageMetadata?
    let metadataIsOverlay: Bool
    let threadLabel: String?
    let standaloneText: String?
    let layoutKey: RowLayoutKey

    /// Native metadata and the hosted duration label share the audio footer.
    var voiceMetrics: VoiceMessageBubbleMetrics {
        .init(
            bodySize: environment.bodySize, captionSize: environment.captionSize,
            metadataSize: metadata?.size ?? .zero)
    }

    /// Resolve only the source identifier here; playback owns all file/network I/O.
    var audioURL: URL? {
        guard case .message(let message) = row, message.entry.messageType == .audio,
            message.entry.remoteMessage?.isDeleted != true
        else { return nil }
        switch message.entry {
        case .pending(let pending):
            if let remote = pending.optimisticMessage, let attachment = remote.attachments.first {
                return URL(string: attachment.url)
            }
            guard pending.attachments.count == 1, let attachment = pending.attachments.first,
                attachment.mimeType.lowercased().hasPrefix("audio/"),
                !attachment.uploadPath.isEmpty
            else { return nil }
            return URL(fileURLWithPath: attachment.uploadPath)
        case .remote(let remote):
            guard remote.attachments.count == 1, let attachment = remote.attachments.first,
                attachment.kind.lowercased().hasPrefix("audio/"),
                let url = URL(string: attachment.url),
                url.scheme?.lowercased() == "https", url.host?.isEmpty == false
            else { return nil }
            return url
        }
    }

    /// A pure function of its arguments: hosts reuse a presentation while `row` and
    /// `environment` are unchanged. Any new input must enter through one of them.
    @MainActor
    static func make(
        row: TimelineRow, currentUserID: Int32?, isThreadTimeline: Bool,
        environment: TimelineLayoutEnvironment
    ) -> Self {
        var title: TitleContent?
        var reply: MessagePreview?
        var originLabel: String?
        var originalReply: MessagePreview?
        var forwardedCardLines: [String] = []
        var markdown: MarkdownDocument?
        var metadata: MessageMetadata?
        var overlay = false
        var threadLabel: String?
        var standaloneText: String?
        var sections: [RowSectionKey] = []
        switch row {
        case .message(let message):
            let remote = message.entry.presentationMessage
            let deleted = remote?.isDeleted == true
            let system = message.entry.messageType == .system
            let sticker = message.entry.messageType == .sticker
            let audio = message.entry.messageType == .audio
            let card = message.entry.messageType == .forwarded
            let placeholder = message.entry.messageType == .placeholder
            let supported =
                message.entry.messageType == .text || message.entry.messageType == .file || sticker
                || audio || card || placeholder
            sections.append(
                .kind(
                    system
                        ? "system"
                        : deleted
                            ? "deleted"
                            : sticker
                                ? "sticker" : audio ? "audio" : supported ? "text" : "unsupported"))
            if system {
                standaloneText =
                    deleted ? AppLanguage.localized("[Deleted]") : message.entry.text ?? ""
                sections.append(
                    .standalone(
                        standaloneText!,
                        author: remote?.sender.name.flatMap { $0.isEmpty ? nil : $0 }))
            } else {
                let sender = message.entry.sender
                let name =
                    sender?.name.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "User \(message.entry.senderID)"
                title =
                    message.showsSenderName && !sticker && !card
                    ? .init(
                        name: name, userGroup: sender?.userGroup,
                        genderGlyph: sender?.gender == 2 ? "♀" : "♂") : nil
                sections.append(
                    .grouping(
                        outgoing: message.isOutgoing, position: message.groupPosition,
                        title: title != nil,
                        avatar: message.groupPosition == .single || message.groupPosition == .last))
                sections.append(.title(title))
                if !deleted && supported {
                    if !sticker && !card, let origin = remote?.forwardedFrom {
                        originLabel = AppLanguage.localized(
                            "Forwarded from \(origin.sender.name ?? "User \(origin.sender.uid)")")
                        originalReply = origin.originalReplyTo.flatMap { $0.isDeleted ? nil : $0 }
                    }
                    if message.capturedReplyRedacted {
                        originLabel = AppLanguage.localized("[Redacted]")
                    }
                    if let originLabel { sections.append(.standalone(originLabel, author: nil)) }
                    if let originalReply { sections.append(.reply(originalReply)) }
                    if card {
                        forwardedCardLines = [AppLanguage.localized("Chat history")]
                        if let preview = remote?.forwardedPreview {
                            forwardedCardLines += preview.messages.prefix(3).map {
                                "\($0.sender.name ?? "User \($0.sender.uid)"): \(MessageSummaryContent.forwardedSummary($0))"
                            }
                            forwardedCardLines.append(
                                AppLanguage.localized("\(preview.total) messages"))
                        }
                        sections.append(
                            .standalone(forwardedCardLines.joined(separator: "\n"), author: nil))
                    }
                    reply = message.entry.replyToMessage.flatMap { $0.isDeleted ? nil : $0 }
                    if let reply {
                        // Source/mention changes can alter styles and concealed
                        // glyph widths even when the plain summary is unchanged.
                        sections.append(.reply(reply))
                    }
                    let text =
                        placeholder
                        ? MessageSummaryContent.placeholderLabel(message.entry.text)
                        : message.entry.text ?? ""
                    let hasBody =
                        !card && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let dimensions: [CGSize]
                    if audio || card || placeholder {
                        dimensions = []
                    } else if case .pending(let pending) = message.entry,
                        pending.forwardRequest == nil
                    {
                        dimensions = pending.attachments.map(\.mediaDimensions)
                    } else {
                        dimensions = (remote?.attachments ?? []).map(\.mediaDimensions)
                    }
                    overlay = sticker || (!audio && !dimensions.isEmpty && !hasBody)
                    if sticker {
                        sections.append(
                            .sticker(
                                CGSize(
                                    width: Int(message.entry.sticker?.media.width ?? 0),
                                    height: Int(message.entry.sticker?.media.height ?? 0))))
                    } else if audio {
                        sections.append(.audio)
                    } else {
                        if hasBody { markdown = MarkdownDocument(parsing: text) }
                        let names = MessageMentions.names(in: remote?.mentions ?? [])
                        let source = text as NSString
                        let labels = MessageMentions.pattern.matches(
                            in: text, range: NSRange(location: 0, length: source.length)
                        ).compactMap { match -> String? in
                            guard let uid = Int32(source.substring(with: match.range(at: 1))) else {
                                return nil
                            }
                            return names[uid] ?? "User \(uid)"
                        }
                        sections.append(.body(hasBody ? text : "", mentionLabels: labels))
                        sections.append(
                            .media(
                                dimensions, category: dimensions.count > 1 ? "gallery" : "single"))
                    }
                    let formatter = Self.formatter(
                        .time, locale: environment.localeIdentifier + "@hours=h23",
                        timeZone: environment.timeZoneIdentifier)
                    let time =
                        formatter.string(from: message.entry.createdAt)
                        + (remote?.isEdited == true ? " " + AppLanguage.localized("(Edited)") : "")
                    metadata = MessageMetadata(
                        time: time, state: message.isOutgoing ? message.entry.displayState : nil,
                        isOutgoing: message.isOutgoing, isRead: message.isRead, isOverlay: overlay,
                        fontSize: environment.caption2Size)
                    sections.append(.metadata(metadata!.size, overlay: overlay))
                } else {
                    standaloneText =
                        deleted
                        ? AppLanguage.localized("Message deleted")
                        : AppLanguage.localized("This message type isn’t supported yet")
                    sections.append(.standalone(standaloneText!, author: nil))
                }
                if !deleted {
                    for reaction in (remote?.reactions ?? []).sorted(by: Self.reactionOrder) {
                        sections.append(
                            .reaction(
                                emoji: reaction.emoji, count: Int64(reaction.count),
                                reactors: min(5, reaction.reactors?.count ?? 0)))
                    }
                    if !isThreadTimeline, let count = remote?.threadInfo?.replyCount {
                        threadLabel =
                            count == 1
                            ? AppLanguage.localized("1 reply")
                            : AppLanguage.localized("\(count) replies")
                        sections.append(.thread(threadLabel!))
                    }
                }
            }
        case .dateSeparator(let date):
            let formatter = Self.formatter(
                .day, locale: environment.localeIdentifier,
                timeZone: environment.timeZoneIdentifier)
            standaloneText = formatter.string(from: date.day)
            sections = [.kind("date"), .standalone(standaloneText!, author: nil)]
        case .unreadSeparator:
            standaloneText = AppLanguage.localized("Below are unread messages")
            sections = [.kind("unread"), .standalone(standaloneText!, author: nil)]
        }
        return .init(
            row: row, environment: environment, title: title, reply: reply,
            originLabel: originLabel, originalReply: originalReply,
            forwardedCardLines: forwardedCardLines, markdown: markdown,
            metadata: metadata,
            metadataIsOverlay: overlay, threadLabel: threadLabel, standaloneText: standaloneText,
            layoutKey: .init(sections: sections))
    }

    private enum FormatterStyle { case time, day }
    private struct FormatterKey: Hashable {
        let style: FormatterStyle
        let locale: String
        let timeZone: String
    }
    /// DateFormatter construction is expensive; one per style/locale/zone suffices.
    @MainActor private static var formatters: [FormatterKey: DateFormatter] = [:]

    @MainActor
    private static func formatter(_ style: FormatterStyle, locale: String, timeZone: String)
        -> DateFormatter
    {
        let key = FormatterKey(style: style, locale: locale, timeZone: timeZone)
        if let formatter = formatters[key] { return formatter }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.timeZone = TimeZone(identifier: timeZone)
        switch style {
        case .time: formatter.dateFormat = "HH:mm"
        case .day: formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        }
        formatters[key] = formatter
        return formatter
    }

    static func reactionOrder(_ lhs: ReactionSummary, _ rhs: ReactionSummary) -> Bool {
        lhs.count == rhs.count ? lhs.emoji < rhs.emoji : lhs.count > rhs.count
    }
}
