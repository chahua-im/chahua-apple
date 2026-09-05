import SwiftUI
import ChahuaAPI

enum DesignSystemFixtures {
    static let displayName = "Ada Lovelace"
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let successfulImage = RemoteImagePhase.success(Image(systemName: "photo"))

    #if DEBUG
    static var textBubbleRows: [TimelineRow] {
        var entries = textBubbleMessages.map(ConversationTimelineEntry.remote)
        for (index, state) in [PendingOutgoingMessage.State.queued, .sending, .failed].enumerated() {
            let id = "pending-\(index)"
            entries.append(.pending(PendingOutgoingMessage(
                chatID: "bubble-fixtures", clientGeneratedID: id,
                body: CreateMessageBody(messageType: .text, clientGeneratedId: id, message: "Pending: \(state.rawValue)"),
                enqueuedAt: bubbleDate.addingTimeInterval(Double(60 + index)), senderID: 1, state: state
            )))
        }
        return bubbleRowsBuilder(isGroupChat: true).build(entries)
    }

    static var directTextBubbleRows: [TimelineRow] {
        bubbleRowsBuilder(isGroupChat: false).build(Array(textBubbleMessages.prefix(2)))
    }

    static var textBubbleMessages: [MessageResponse] {
        let cases: [(Int32, String?, String?)] = [
            (2, "Ada", "Hello"), (1, "Me", "Hello"),
            (2, "Ada", String(repeating: "A long message wraps naturally without hiding its timestamp. ", count: 5)),
            (1, "Me", "First line\nSecond line"),
            (3, "小明", "你好，世界！🌸 👨‍👩‍👧‍👦"),
            (1, "Me", String(repeating: "x", count: 160)),
            (2, "Ada", "Literal \"quotes\", *asterisks*, and `backticks`"),
            (4, nil, nil), (5, "", ""),
            (6, String(repeating: "A very long sender name ", count: 8), "Body remains readable"),
            (7, "Grouped sender", "First in group"),
            (7, "Grouped sender", "Middle in group"),
            (7, "Grouped sender", "Last in group"),
            (8, "Different sender", "New group"),
            (9, "Deleted", "Deleted control"),
            (10, "Unsupported", "Unsupported control"),
            (11, "System", "System control")
        ]
        let formatter = ISO8601DateFormatter()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return cases.enumerated().map { index, item in
            let object: [String: Any] = [
                "id": "bubble-\(index)", "chatId": "bubble-fixtures", "clientGeneratedId": "bubble-client-\(index)",
                "messageType": index == 15 ? "image" : index == 16 ? "system" : "text",
                "sender": ["uid": item.0, "gender": 0, "name": item.1 as Any? ?? NSNull(), "avatarUrl": NSNull(), "userGroup": NSNull()],
                "createdAt": formatter.string(from: bubbleDate.addingTimeInterval(Double(index))),
                "isEdited": false, "isDeleted": index == 14, "hasAttachments": false,
                "attachments": [], "reactions": [], "mentions": [], "message": item.2 as Any? ?? NSNull()
            ]
            do {
                return try decoder.decode(MessageResponse.self, from: JSONSerialization.data(withJSONObject: object))
            } catch {
                preconditionFailure("Invalid text bubble fixture \(index): \(error)")
            }
        }
    }

    private static let bubbleDate = ISO8601DateFormatter().date(from: "2026-09-01T13:05:00Z")!

    private static func bubbleRowsBuilder(isGroupChat: Bool) -> TimelineRowsBuilder {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return TimelineRowsBuilder(currentUserID: 1, isGroupChat: isGroupChat, calendar: calendar)
    }
    #endif
}
