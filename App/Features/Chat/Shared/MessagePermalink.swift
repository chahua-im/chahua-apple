import ChahuaAPI
import Foundation

/// The PWA `/m/:encoded` wire format: two unsigned 64-bit IDs in network byte order.
/// A reply's thread is resolved from its authoritative message, never encoded separately.
struct MessagePermalink: Hashable, Sendable {
    let chatID: String
    let messageID: MessageID

    init?(chatID: String, messageID: MessageID) {
        guard let chat = UInt64(chatID), chat > 0, messageID.rawValue > 0 else { return nil }
        self.chatID = String(chat)
        self.messageID = messageID
    }

    init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "m" else { return nil }
        let encoded = parts[1]
        guard encoded.count == 22,
            encoded.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || byte == 45 || byte == 95
            })
        else { return nil }
        let base64 =
            encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "=="
        guard let bytes = Data(base64Encoded: base64), bytes.count == 16 else { return nil }
        let chat = bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let message = bytes.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        self.init(chatID: String(chat), messageID: MessageID(message))
    }

    var url: URL {
        var bytes = Data(capacity: 16)
        for value in [UInt64(chatID)!, messageID.rawValue] {
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        let encoded = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents(
            url: AppConfiguration.applicationURL, resolvingAgainstBaseURL: false)!
        components.path = "/m/\(encoded)"
        components.query = nil
        components.fragment = nil
        return components.url!
    }
}
