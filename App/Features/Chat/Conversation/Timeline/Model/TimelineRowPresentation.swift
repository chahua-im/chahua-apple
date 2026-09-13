import ChahuaAPI
import SwiftUI

struct TitleContent: Hashable {
    let name: String
    let groupName: String?
    let genderGlyph: String?
}

enum RowSectionKey: Hashable {
    case kind(String)
    case grouping(outgoing: Bool, position: TimelineGroupPosition, title: Bool, avatar: Bool)
    case title(TitleContent?)
    case body(String, mentionLabels: [String])
    case reply(author: String, preview: String)
    case media([CGSize], category: String)
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
    let metadata: MessageMetadata?
    let metadataIsOverlay: Bool
    let threadLabel: String?
    let standaloneText: String?
    let layoutKey: RowLayoutKey

    @MainActor
    static func make(row: TimelineRow, currentUserProfile: MeResponse?, currentUserID: Int32?, isThreadTimeline: Bool, environment: TimelineLayoutEnvironment) -> Self {
        var title: TitleContent?
        var reply: MessagePreview?
        var metadata: MessageMetadata?
        var overlay = false
        var threadLabel: String?
        var standaloneText: String?
        var sections: [RowSectionKey] = []
        switch row {
        case .message(let message):
            let remote = message.entry.remoteMessage
            let deleted = remote?.isDeleted == true
            let system = message.entry.messageType == .system
            let sticker = message.entry.messageType == .sticker
            let supported = message.entry.messageType == .text || sticker
            sections.append(.kind(system ? "system" : deleted ? "deleted" : sticker ? "sticker" : supported ? "text" : "unsupported"))
            if system {
                standaloneText = deleted ? String(localized: "[Deleted]") : message.entry.text ?? ""
                sections.append(.standalone(standaloneText!, author: remote?.sender.name.flatMap { $0.isEmpty ? nil : $0 }))
            } else {
                let sender = remote?.sender
                let fallback = (message.isOutgoing ? currentUserProfile?.username : nil) ?? "User \(message.entry.senderID)"
                let name = sender?.name.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
                title = message.showsSenderName && !sticker ? .init(name: name, groupName: sender?.userGroup?.name.flatMap { $0.isEmpty ? nil : $0 }, genderGlyph: sender?.gender == 2 ? "♀" : "♂") : nil
                sections.append(.grouping(outgoing: message.isOutgoing, position: message.groupPosition, title: title != nil, avatar: message.groupPosition == .single || message.groupPosition == .last))
                sections.append(.title(title))
                if !deleted && supported {
                    reply = message.entry.replyToMessage.flatMap { $0.isDeleted ? nil : $0 }
                    if let reply { sections.append(.reply(author: reply.sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(reply.sender.uid)", preview: messagePreview(reply))) }
                    let text = message.entry.text ?? ""
                    let hasBody = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let dimensions: [CGSize]
                    if case .pending(let pending) = message.entry { dimensions = pending.attachments.map(\.mediaDimensions) }
                    else { dimensions = (remote?.attachments ?? []).map(\.mediaDimensions) }
                    overlay = sticker || (!dimensions.isEmpty && !hasBody)
                    if sticker {
                        sections.append(.sticker(CGSize(width: Int(remote?.sticker?.media.width ?? 0), height: Int(remote?.sticker?.media.height ?? 0))))
                    } else {
                        let names = MessageMentions.names(in: remote?.mentions ?? [])
                        let source = text as NSString
                        let labels = MessageMentions.pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match -> String? in
                            guard let uid = Int32(source.substring(with: match.range(at: 1))) else { return nil }
                            return names[uid] ?? "User \(uid)"
                        }
                        sections.append(.body(hasBody ? text : "", mentionLabels: labels))
                        sections.append(.media(dimensions, category: dimensions.count > 1 ? "gallery" : "single"))
                    }
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: environment.localeIdentifier + "@hours=h23")
                    formatter.timeZone = TimeZone(identifier: environment.timeZoneIdentifier)
                    formatter.dateFormat = "HH:mm"
                    let time = formatter.string(from: message.entry.createdAt) + (remote?.isEdited == true ? " " + String(localized: "(Edited)") : "")
                    metadata = MessageMetadata(time: time, state: message.isOutgoing ? message.entry.displayState : nil, isOutgoing: message.isOutgoing, isOverlay: overlay, fontSize: overlay ? environment.caption2Size : environment.captionSize)
                    sections.append(.metadata(metadata!.size, overlay: overlay))
                } else {
                    standaloneText = deleted ? String(localized: "Message deleted") : String(localized: "This message type isn’t supported yet")
                    sections.append(.standalone(standaloneText!, author: nil))
                }
                if !deleted {
                    for reaction in (remote?.reactions ?? []).sorted(by: Self.reactionOrder) {
                        sections.append(.reaction(emoji: reaction.emoji, count: Int64(reaction.count), reactors: min(5, reaction.reactors?.count ?? 0)))
                    }
                    if !isThreadTimeline, let count = remote?.threadInfo?.replyCount {
                        threadLabel = count == 1 ? String(localized: "1 reply") : String(localized: "\(count) replies")
                        sections.append(.thread(threadLabel!))
                    }
                }
            }
        case .dateSeparator(let date):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: environment.localeIdentifier)
            formatter.timeZone = TimeZone(identifier: environment.timeZoneIdentifier)
            formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
            standaloneText = formatter.string(from: date.day)
            sections = [.kind("date"), .standalone(standaloneText!, author: nil)]
        case .unreadSeparator:
            standaloneText = String(localized: "Below are unread messages")
            sections = [.kind("unread"), .standalone(standaloneText!, author: nil)]
        }
        return .init(row: row, environment: environment, title: title, reply: reply, metadata: metadata, metadataIsOverlay: overlay, threadLabel: threadLabel, standaloneText: standaloneText, layoutKey: .init(sections: sections))
    }

    static func reactionOrder(_ lhs: ReactionSummary, _ rhs: ReactionSummary) -> Bool {
        lhs.count == rhs.count ? lhs.emoji < rhs.emoji : lhs.count > rhs.count
    }
}
