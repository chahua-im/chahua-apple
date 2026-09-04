import Foundation
import ChahuaAPI

@MainActor
enum TimelineTestFixtures {
    static func message(
        id: String,
        chatID: String = "chat",
        senderID: Int32 = 1,
        senderName: String? = "Ada",
        at second: Int,
        dayOffset: Int = 0,
        hour: Int = 0,
        minute: Int = 0,
        type: MessageType = .text,
        text: String? = nil,
        isDeleted: Bool = false,
        clientGeneratedID: String? = nil
    ) throws -> MessageResponse {
        let data = Data("""
        {
          "id": "\(id)", "chatId": "\(chatID)", "clientGeneratedId": "\(clientGeneratedID ?? "client-\(id)")", "messageType": "\(type.rawValue)",
          "sender": {"uid": \(senderID), "gender": 0, "name": \(jsonString(senderName)), "avatarUrl": null, "userGroup": null},
          "createdAt": "2026-09-\(String(format: "%02d", 1 + dayOffset))T\(String(format: "%02d", hour)):\(String(format: "%02d", minute)):\(String(format: "%02d", second))Z", "isEdited": false, "isDeleted": \(isDeleted),
          "hasAttachments": false, "attachments": [], "reactions": [], "mentions": [], "message": \(jsonString(text ?? "message \(id)"))
        }
        """.utf8)
        return try decoder.decode(MessageResponse.self, from: data)
    }

    static func page(
        _ messages: [MessageResponse],
        olderCursor: String? = nil,
        newerCursor: String? = nil
    ) throws -> ListMessagesResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let messagesJSON = try String(decoding: encoder.encode(messages), as: UTF8.self)
        return try decoder.decode(
            ListMessagesResponse.self,
            from: Data("{\"messages\":\(messagesJSON),\"olderCursor\":\(jsonString(olderCursor)),\"newerCursor\":\(jsonString(newerCursor))}".utf8)
        )
    }

    static func date(dayOffset: Int = 0, second: Int) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: dayOffset, to: Date(timeIntervalSince1970: 1_788_220_800))!
            .addingTimeInterval(TimeInterval(second))
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func jsonString(_ value: String?) -> String {
        guard let value else { return "null" }
        return "\"\(value)\""
    }
}
