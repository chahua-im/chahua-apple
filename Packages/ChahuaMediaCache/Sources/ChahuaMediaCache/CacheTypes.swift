import Foundation
import CryptoKit

public struct CacheTag: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct MediaRequest: Sendable {
    public let request: URLRequest
    public let tags: Set<CacheTag>
    public init(request: URLRequest, tags: Set<CacheTag>) {
        self.request = request
        self.tags = tags
    }

    func normalized() throws -> (request: URLRequest, key: String) {
        guard let url = request.url, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              (request.httpMethod ?? "GET") == "GET",
              request.httpBody == nil, request.httpBodyStream == nil else {
            throw MediaCacheError.invalidRequest
        }
        try Self.validate(tags: tags)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        guard let absolute = components?.url, absolute.baseURL == nil else {
            throw MediaCacheError.invalidRequest
        }
        let forbidden = Set(["range", "if-range", "if-match", "if-none-match", "if-modified-since", "if-unmodified-since"])
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            guard !forbidden.contains(name.lowercased()),
                  name.lowercased() != "accept-encoding" || value.lowercased() == "identity" else {
                throw MediaCacheError.invalidRequest
            }
        }
        var result = request
        result.url = absolute
        result.httpMethod = "GET"
        result.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        result.cachePolicy = .reloadIgnoringLocalCacheData
        result.httpShouldHandleCookies = false
        var encoded = Data()
        func append(_ string: String) {
            let bytes = Data(string.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { encoded.append(contentsOf: $0) }
            encoded.append(bytes)
        }
        append(absolute.absoluteString)
        append("GET")
        for (name, value) in (result.allHTTPHeaderFields ?? [:]).map({ ($0.key.lowercased(), $0.value) }).sorted(by: { $0.0 < $1.0 }) {
            append(name)
            append(value)
        }
        return (result, SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined())
    }

    static func validate(tags: Set<CacheTag>) throws {
        guard !tags.isEmpty, tags.allSatisfy({ !$0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MediaCacheError.invalidTag
        }
    }
}

public struct CacheConfiguration: Sendable {
    public let directory: URL
    public let maximumDiskBytes: Int64
    public init(directory: URL, maximumDiskBytes: Int64 = 1_073_741_824) {
        self.directory = directory
        self.maximumDiskBytes = maximumDiskBytes
    }
}

/// Semantic revocation of presented content, independent of file lease lifetime.
public enum CacheInvalidation: Sendable {
    case all
    case tags(Set<CacheTag>)
    case contentIdentifier(String)
}

public struct CacheUsage: Sendable {
    public let total: CacheUsageBucket
    public let byTag: [CacheTag: CacheUsageBucket]
    public let overheadDiskBytes: Int64
}

public struct CacheUsageBucket: Sendable {
    public internal(set) var itemCount: Int = 0
    public internal(set) var completeItemCount: Int = 0
    public internal(set) var cachedBytes: Int64 = 0
    public internal(set) var allocatedDiskBytes: Int64 = 0
    public internal(set) var transientDiskBytes: Int64 = 0
}

public struct CacheRemoval: Sendable {
    public let removedItemCount: Int
    public let removedCachedBytes: Int64
    public let removedAllocatedDiskBytes: Int64
    public let remainingAllocatedDiskBytes: Int64
}

public enum MediaCacheError: Error, Sendable, Equatable {
    case invalidRequest, invalidTag, invalidConfiguration, missingEntry, closed, invalidated
    case httpStatus(Int)
    case invalidResponse, quotaExceeded, storageFailure
}

public final class CachedFile: Sendable {
    public let url: URL
    public let key: String
    private let state: LeaseState

    init(url: URL, key: String, validate: @escaping @Sendable () async throws -> Void,
         release: @escaping @Sendable () async -> Void) {
        self.url = url
        self.key = key
        state = LeaseState(validate: validate, release: release)
    }

    public func release() async { await state.release() }
    public func checkValidity() async throws { try await state.checkValidity() }
    deinit {
        let state = state
        Task { await state.release() }
    }
}

private actor LeaseState {
    private var released = false
    private let validate: @Sendable () async throws -> Void
    private let relinquish: @Sendable () async -> Void
    init(validate: @escaping @Sendable () async throws -> Void, release: @escaping @Sendable () async -> Void) {
        self.validate = validate
        relinquish = release
    }
    func release() async {
        guard !released else { return }
        released = true
        await relinquish()
    }
    func checkValidity() async throws {
        guard !released else { throw MediaCacheError.invalidated }
        try await validate()
        guard !released else { throw MediaCacheError.invalidated }
    }
}
