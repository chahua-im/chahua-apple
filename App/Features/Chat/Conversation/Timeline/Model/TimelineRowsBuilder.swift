import ChahuaAPI
import Foundation

enum TimelineRowID: Hashable {
    case message(ConversationMessageStableKey)
    case dateSeparator(Int)
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

    var id: TimelineRowID {
        switch self {
        case .message(let row): .message(row.entry.stableKey)
        case .dateSeparator(let row): .dateSeparator(row.ordinalDay)
        }
    }

    var messageID: String? {
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
    var groupingGap: TimeInterval = 300
    func build(_ messages: [MessageResponse]) -> [TimelineRow] {
        build(messages.map(ConversationTimelineEntry.remote))
    }

    func build(_ entries: [ConversationTimelineEntry]) -> [TimelineRow] {
        guard !entries.isEmpty else { return [] }

        var rows: [TimelineRow] = []
        rows.reserveCapacity(entries.count * 2)

        var previousDay: Int?
        for index in entries.indices {
            let entry = entries[index]
            let day = calendar.startOfDay(for: entry.createdAt)
            let ordinalDay = calendar.ordinality(of: .day, in: .era, for: day)!
            if previousDay != ordinalDay {
                rows.append(.dateSeparator(.init(day: day, ordinalDay: ordinalDay)))
                previousDay = ordinalDay
            }

            let groupedWithPrevious = index > entries.startIndex && grouped(entries[index - 1], entry)
            let groupedWithNext = index < entries.index(before: entries.endIndex) && grouped(entry, entries[index + 1])
            let groupPosition = groupPosition(
                groupedWithPrevious: groupedWithPrevious,
                groupedWithNext: groupedWithNext
            )
            let isOutgoing = entry.senderID == currentUserID
            let showsSenderName = entry.messageType != .system
                && (groupPosition == .single || groupPosition == .first)

            rows.append(.message(.init(
                entry: entry,
                isOutgoing: isOutgoing,
                groupPosition: groupPosition,
                showsSenderName: showsSenderName
            )))
        }

        return rows
    }

    private func grouped(_ earlier: ConversationTimelineEntry, _ later: ConversationTimelineEntry) -> Bool {
        earlier.senderID == later.senderID
            && earlier.messageType != .system
            && later.messageType != .system
            && calendar.isDate(earlier.createdAt, inSameDayAs: later.createdAt)
            && later.createdAt.timeIntervalSince(earlier.createdAt) <= groupingGap
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
