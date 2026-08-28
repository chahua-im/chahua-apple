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
