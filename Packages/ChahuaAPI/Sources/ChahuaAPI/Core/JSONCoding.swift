import Foundation

enum JSONCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            do {
                return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
            } catch {
                do {
                    return try Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(value)
                } catch {
                    throw DecodingError.dataCorruptedError(
                        in: try decoder.singleValueContainer(),
                        debugDescription: "Expected an RFC3339 timestamp."
                    )
                }
            }
        }
        return decoder
    }()

    /// Keep structural decoding evidence, never values from debugDescription or underlying errors.
    static func decodingDescription(_ error: Error) -> String {
        let context: DecodingError.Context
        let reason: String
        var missingKey: CodingKey?
        switch error {
        case DecodingError.keyNotFound(let key, let detail):
            context = detail
            missingKey = key
            reason = "missing required field"
        case DecodingError.valueNotFound(let type, let detail):
            context = detail
            reason = "null value; expected \(String(reflecting: type))"
        case DecodingError.typeMismatch(let type, let detail):
            context = detail
            reason = "type mismatch; expected \(String(reflecting: type))"
        case DecodingError.dataCorrupted(let detail):
            context = detail
            reason = "invalid value or malformed JSON"
        default:
            return "decoder failure (\(String(reflecting: type(of: error))))"
        }
        let keys = context.codingPath + (missingKey.map { [$0] } ?? [])
        let path = keys.reduce("$") { path, key in
            if let index = key.intValue { return "\(path)[\(index)]" }
            return "\(path).\(key.stringValue)"
        }
        return "\(path): \(reason)"
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
