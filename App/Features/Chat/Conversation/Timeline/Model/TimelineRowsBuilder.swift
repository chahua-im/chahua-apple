import ChahuaAPI
import Foundation

enum TimelineRowID: Hashable {
    case message(ConversationMessageStableKey)
    case dateSeparator(Int)
    case unreadSeparator
}

enum TimelineGroupPosition: Hashable {
    case single
    case first
    case middle
    case last
}

struct TimelineMessageRow: Hashable {
    let entry: ConversationTimelineEntry
    let isOutgoing: Bool
    let groupPosition: TimelineGroupPosition
    let showsSenderName: Bool
}

struct TimelineDateSeparatorRow: Hashable {
    let day: Date
    let ordinalDay: Int
}

enum TimelineRow: Hashable, Identifiable {
    case message(TimelineMessageRow)
    case dateSeparator(TimelineDateSeparatorRow)
    case unreadSeparator

    var id: TimelineRowID {
        switch self {
        case .message(let row): .message(row.entry.stableKey)
        case .dateSeparator(let row): .dateSeparator(row.ordinalDay)
        case .unreadSeparator: .unreadSeparator
        }
    }

    var messageID: MessageID? {
        guard case .message(let row) = self else { return nil }
        return row.entry.serverID
    }

    var stableMessageKey: ConversationMessageStableKey? {
        guard case .message(let row) = self else { return nil }
        return row.entry.stableKey
    }
}

struct TimelineRowsBuilder {
    var currentUserID: Int32
    var isGroupChat: Bool

    var calendar: Calendar
    func build(_ messages: [MessageResponse], unreadBeforeMessageID: MessageID? = nil)
        -> [TimelineRow]
    {
        build(
            messages.map(ConversationTimelineEntry.remote),
            unreadBeforeMessageID: unreadBeforeMessageID)
    }

    /// `entries` are confirmed messages in server order followed by pending sends.
    func build(_ entries: [ConversationTimelineEntry], unreadBeforeMessageID: MessageID? = nil)
        -> [TimelineRow]
    {
        guard !entries.isEmpty else { return [] }

        var rows: [TimelineRow] = []
        rows.reserveCapacity(entries.count * 2)

        var previousDay: Int?
        let unreadIndex = unreadBeforeMessageID.flatMap { id in
            entries.firstIndex { $0.serverID == id }
        }
        for index in entries.indices {
            let entry = entries[index]
            let day = calendar.startOfDay(for: entry.createdAt)
            let ordinalDay = calendar.ordinality(of: .day, in: .era, for: day)!
            // Separators only advance: a pending send created on an earlier day (or a
            // cross-node timestamp at midnight) stays under the current separator rather
            // than emitting a second separator with the same row identity.
            if previousDay.map({ ordinalDay > $0 }) ?? true {
                rows.append(.dateSeparator(.init(day: day, ordinalDay: ordinalDay)))
                previousDay = ordinalDay
            }

            if index == unreadIndex { rows.append(.unreadSeparator) }
            // A visible separator starts a new run even when the sender is unchanged.
            let groupedWithPrevious =
                index > entries.startIndex && index != unreadIndex
                && grouped(entries[index - 1], entry)
            let groupedWithNext =
                index < entries.index(before: entries.endIndex) && index + 1 != unreadIndex
                && grouped(entry, entries[index + 1])
            let groupPosition = groupPosition(
                groupedWithPrevious: groupedWithPrevious,
                groupedWithNext: groupedWithNext
            )
            let isOutgoing = entry.senderID == currentUserID
            #if os(macOS)
                let showsSenderName =
                    isGroupChat
                    && entry.messageType != .system
                    && (groupPosition == .single || groupPosition == .first)
            #else
                let showsSenderName =
                    entry.messageType != .system
                    && (groupPosition == .single || groupPosition == .first)
            #endif
            rows.append(
                .message(
                    .init(
                        entry: entry,
                        isOutgoing: isOutgoing,
                        groupPosition: groupPosition,
                        showsSenderName: showsSenderName
                    )))
        }

        return rows
    }

    private func grouped(_ earlier: ConversationTimelineEntry, _ later: ConversationTimelineEntry)
        -> Bool
    {
        guard earlier.senderID == later.senderID,
            earlier.messageType != .system,
            later.messageType != .system,
            calendar.isDate(earlier.createdAt, inSameDayAs: later.createdAt)
        else { return false }
        return true
    }

    private func groupPosition(
        groupedWithPrevious: Bool,
        groupedWithNext: Bool
    ) -> TimelineGroupPosition {
        switch (groupedWithPrevious, groupedWithNext) {
        case (false, false): .single
        case (false, true): .first
        case (true, true): .middle
        case (true, false): .last
        }
    }
}
