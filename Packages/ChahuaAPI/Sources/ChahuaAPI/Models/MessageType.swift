public struct MessageType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let text = MessageType(rawValue: "text")
    public static let audio = MessageType(rawValue: "audio")
    public static let file = MessageType(rawValue: "file")
    public static let sticker = MessageType(rawValue: "sticker")
    public static let invite = MessageType(rawValue: "invite")
    public static let system = MessageType(rawValue: "system")
}
