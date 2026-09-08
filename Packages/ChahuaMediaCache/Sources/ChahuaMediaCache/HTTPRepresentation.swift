import Foundation

/// Cache metadata for a complete representation or a conditional validation.
/// The transport verifies the delivered body's length before completing.
struct HTTPRepresentation: Sendable {
    let statusCode: Int
    let contentLength: Int64?
    let mimeType: String?
    let etag: String?
    let lastModified: String?
    let freshUntil: Date
    let retained: Bool

    init(response: HTTPURLResponse, sentAt: Date, receivedAt: Date) throws {
        statusCode = response.statusCode
        contentLength = try Self.validatedContentLength(of: response)
        mimeType = Self.field("Content-Type", response)?.split(separator: ";", maxSplits: 1)
            .first.map { Self.trim(String($0)).lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        etag = Self.field("ETag", response).flatMap(Self.entityTag)
        lastModified = Self.field("Last-Modified", response).flatMap {
            Self.httpDate($0) == nil ? nil : $0
        }
        let directives = Self.cacheDirectives(Self.field("Cache-Control", response) ?? "")
        retained = !directives.contains { $0.name == "no-store" }
            && !(Self.field("Vary", response)?.split(separator: ",").contains { Self.trim(String($0)) == "*" } ?? false)
        freshUntil = Self.expiration(response, directives: directives, sentAt: sentAt, receivedAt: receivedAt)
    }

    private static func field(_ name: String, _ response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: name).map(trim)
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    private static func decimal(_ value: String) -> Int64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int64(value)
    }

    /// A 304's Content-Length describes the selected representation, not a body.
    /// Its caller must compare any supplied value with the stored complete file.
    static func validatedContentLength(of response: HTTPURLResponse) throws -> Int64? {
        guard response.statusCode == 200 || response.statusCode == 304 else {
            throw MediaCacheError.httpStatus(response.statusCode)
        }
        if let encoding = field("Content-Encoding", response), encoding.lowercased() != "identity" {
            throw MediaCacheError.invalidResponse
        }
        guard field("Content-Range", response) == nil else { throw MediaCacheError.invalidResponse }
        guard let value = field("Content-Length", response) else { return nil }
        // HTTP permits normalization of repeated, identical Content-Length fields.
        let values = value.split(separator: ",", omittingEmptySubsequences: false).map { trim(String($0)) }
        guard let first = values.first.flatMap(decimal),
              values.allSatisfy({ decimal($0) == first }) else { throw MediaCacheError.invalidResponse }
        return first
    }


    private static func entityTag(_ value: String) -> String? {
        let opaque = value.hasPrefix("W/") ? value.dropFirst(2) : value[...]
        guard opaque.count >= 2, opaque.first == "\"", opaque.last == "\"",
              opaque.dropFirst().dropLast().utf8.allSatisfy({ $0 == 0x21 || ($0 >= 0x23 && $0 != 0x7f) }) else {
            return nil
        }
        return value
    }

    private struct Directive {
        let name: String
        let value: String?
    }

    private static func cacheDirectives(_ value: String) -> [Directive] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var escaped = false
        for character in value {
            if escaped { escaped = false }
            else if quoted && character == "\\" { escaped = true }
            else if character == "\"" { quoted.toggle() }
            else if character == "," && !quoted {
                fields.append(field)
                field = ""
                continue
            }
            field.append(character)
        }
        fields.append(field)
        return fields.map { field in
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = trim(String(pair[0])).lowercased()
            var argument = pair.count == 2 ? trim(String(pair[1])) : nil
            if let value = argument, value.count >= 2, value.first == "\"", value.last == "\"" {
                argument = String(value.dropFirst().dropLast())
            }
            return Directive(name: name, value: argument)
        }
    }

    private static func expiration(_ response: HTTPURLResponse, directives: [Directive],
                                   sentAt: Date, receivedAt: Date) -> Date {
        guard !directives.contains(where: { $0.name == "no-cache" }) else { return receivedAt }
        let responseDate = field("Date", response).flatMap(httpDate) ?? receivedAt
        let maxAges = directives.filter { $0.name == "max-age" }
        let lifetime: TimeInterval
        if !maxAges.isEmpty {
            guard maxAges.count == 1, let value = maxAges[0].value.flatMap(decimal) else { return receivedAt }
            lifetime = TimeInterval(value)
        } else if let expires = field("Expires", response).flatMap(httpDate) {
            lifetime = max(0, expires.timeIntervalSince(responseDate))
        } else {
            return receivedAt
        }
        let age: TimeInterval
        if let rawAge = field("Age", response) {
            guard let parsed = decimal(rawAge) else { return receivedAt }
            age = TimeInterval(parsed)
        } else { age = 0 }
        let apparentAge = max(0, receivedAt.timeIntervalSince(responseDate))
        let responseDelay = max(0, receivedAt.timeIntervalSince(sentAt))
        let correctedInitialAge = max(apparentAge, age + responseDelay)
        let expiration = receivedAt.addingTimeInterval(lifetime - correctedInitialAge)
        return min(Date.distantFuture, max(Date.distantPast, expiration))
    }

    private static func httpDate(_ value: String) -> Date? {
        guard value.utf8.count <= 64 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
