import Foundation

/// Error surface for HTTP transport, authentication, and protocol failures.
///
/// `invalidToken` means no authenticated session remains after refresh handling.
/// `transport` and `unavailable` are recoverable only according to the calling
/// feature's retry policy. `decoding` must be treated as a wire-contract defect,
/// not silently coerced.
public enum APIError: Error, Sendable {
    case invalidBaseURL(URL)
    case unauthorized
    case invalidToken
    case unavailable
    case invalidResponse(statusCode: Int)
    case http(status: Int, body: Data)
    case retryableHTTP(status: Int, body: Data, retryAfter: Date)
    case decoding(statusCode: Int, description: String)
    case encoding(description: String)
    case transport(URLError)
    case unexpectedResponse

    /// The server's earliest retry time, when a retryable response supplied one.
    public var retryAfter: Date? {
        guard case .retryableHTTP(_, _, let date) = self else { return nil }
        return date
    }

    /// Parses a Retry-After field as delta seconds from receipt or as an HTTP date.
    public static func retryDate(from field: String?, now: Date = Date()) -> Date? {
        guard let value = field?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if value.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = Int(value) else { return nil }
            return now.addingTimeInterval(TimeInterval(seconds))
        }
        if let date = httpDateFormatter.date(from: value) { return date }

        // Accept the obsolete HTTP-date forms as well. RFC 850's two-digit
        // year is interpreted in a moving window rather than Foundation's fixed one.
        guard value.contains(",") else { return asctimeFormatter.date(from: value) }
        let formatter = makeHTTPDateFormatter("EEEE, dd-MMM-yy HH:mm:ss 'GMT'")
        formatter.twoDigitStartDate = formatter.calendar.date(byAdding: .year, value: -50, to: now)
        return formatter.date(from: value)
    }

    private static let httpDateFormatter = makeHTTPDateFormatter("EEE, dd MMM yyyy HH:mm:ss 'GMT'")
    private static let asctimeFormatter = makeHTTPDateFormatter("EEE MMM d HH:mm:ss yyyy")

    private static func makeHTTPDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    /// Only the backend's structured speaking denial is classified; other 403s stay generic.
    public var speakingRestriction: SpeakingMode? {
        guard case .http(status: 403, body: let body) = self,
            let restriction = try? JSONDecoder().decode(SpeakingRestriction.self, from: body),
            restriction.code == "speakingRestricted"
        else { return nil }
        return restriction.effectiveSpeakingMode
    }

    private struct SpeakingRestriction: Decodable {
        let code: String
        let effectiveSpeakingMode: SpeakingMode
    }

    /// A create conflict reports the server copy, not acceptance of the submitted payload.
    /// The caller must validate the account and conversation before using this receipt.
    public var conflictingExistingMessage: MessageResponse? {
        guard case .http(status: 409, body: let body) = self,
            let conflict = try? JSONCoding.decoder.decode(MessageIDConflict.self, from: body),
            conflict.code == "clientGeneratedIdConflict"
        else { return nil }
        return conflict.existingMessage
    }

    private struct MessageIDConflict: Decodable {
        let code: String
        let existingMessage: MessageResponse
    }

    /// UTF-8 response body for an HTTP error, when the server returned one.
    public var bodyText: String? {
        switch self {
        case .http(_, let body), .retryableHTTP(_, let body, _):
            return String(data: body, encoding: .utf8)
        default:
            return nil
        }
    }
}
