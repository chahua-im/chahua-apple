import Foundation

/// Server message identifier.
///
/// The backend allocates message IDs from a time-ordered snowflake generator, so
/// ascending `MessageID` order is the server's message order and the order used by
/// `before`/`after`/`around` paging. The wire format is a decimal string only because
/// JavaScript clients cannot represent 64-bit integers; a non-numeric value is a
/// wire-contract defect and fails decoding.
public struct MessageID: Hashable, Comparable, Sendable, Codable, LosslessStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) { self.rawValue = rawValue }

    /// Parses the decimal wire representation.
    public init?(_ description: String) {
        guard let rawValue = UInt64(description) else { return nil }
        self.rawValue = rawValue
    }

    /// The decimal wire representation, also used for URL path segments and queries.
    public var description: String { String(rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let id = Self(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a decimal message ID.")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
