import Foundation
import XCTest
@testable import ChahuaMediaCache

final class CacheTypesTests: XCTestCase {
    func testIdentityKeepsSignedQueryAndEveryExplicitHeader() throws {
        let original = request("https://media.example/identity?signature=first&revision=1")
        let originalKey = try normalized(original).key
        XCTAssertNotEqual(originalKey, try normalized(request("https://media.example/identity?signature=second&revision=1")).key)
        XCTAssertNotEqual(originalKey, try normalized(request("https://media.example/identity?signature=first&revision=2")).key)

        var authorized = original
        authorized.setValue("Bearer first-account", forHTTPHeaderField: "Authorization")
        var otherAccount = authorized
        otherAccount.setValue("Bearer second-account", forHTTPHeaderField: "Authorization")
        var cookie = authorized
        cookie.setValue("session=explicit-session", forHTTPHeaderField: "Cookie")
        var accept = authorized
        accept.setValue("image/avif", forHTTPHeaderField: "Accept")
        var custom = authorized
        custom.setValue("variant-one", forHTTPHeaderField: "X-Media-Variant")

        let keys = try [original, authorized, otherAccount, cookie, accept, custom].map { try normalized($0).key }
        XCTAssertEqual(Set(keys).count, keys.count, "Different explicit representation or credential inputs must not share cached bytes")
        let result = try normalized(cookie)
        XCTAssertEqual(result.request.value(forHTTPHeaderField: "Authorization"), "Bearer first-account")
        XCTAssertEqual(result.request.value(forHTTPHeaderField: "Cookie"), "session=explicit-session")
        XCTAssertFalse(result.request.httpShouldHandleCookies)
        XCTAssertEqual(result.request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testIdentityIgnoresTagsFragmentsAndHeaderNameCaseOrOrder() throws {
        var first = request("https://media.example/canonical?revision=3#first-fragment")
        first.setValue("Bearer shared", forHTTPHeaderField: "Authorization")
        first.setValue("image/png", forHTTPHeaderField: "Accept")
        var second = request("https://media.example/canonical?revision=3#second-fragment")
        second.setValue("image/png", forHTTPHeaderField: "accept")
        second.setValue("Bearer shared", forHTTPHeaderField: "authorization")

        let left = try MediaRequest(request: first, tags: [CacheTag(rawValue: "avatars")]).normalized()
        let right = try MediaRequest(request: second, tags: [CacheTag(rawValue: "chatMedia"), CacheTag(rawValue: "overlapping")]).normalized()
        XCTAssertEqual(left.key, right.key)
        XCTAssertEqual(left.request.url?.absoluteString, "https://media.example/canonical?revision=3")
        XCTAssertNil(right.request.url?.fragment)
    }

    func testIdentityEncodingIsCanonicalAndUnambiguous() throws {
        let implicit = request("http://media.example/encoding?label=%E9%9B%AA")
        var explicit = implicit
        explicit.setValue("IDENTITY", forHTTPHeaderField: "accept-encoding")
        let first = try normalized(implicit)
        let second = try normalized(explicit)
        XCTAssertEqual(first.key, second.key)
        XCTAssertEqual(first.request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(second.request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(first.key, try normalized(first.request).key, "Re-normalizing the transmitted request must preserve its identity")

        var left = implicit
        left.setValue("bc", forHTTPHeaderField: "X-A")
        var right = implicit
        right.setValue("c", forHTTPHeaderField: "X-Ab")
        XCTAssertNotEqual(try normalized(left).key, try normalized(right).key, "Header names and values need separate encoding boundaries")

        var caseSensitiveValue = implicit
        caseSensitiveValue.setValue("Token", forHTTPHeaderField: "X-Case")
        var lowercaseValue = caseSensitiveValue
        lowercaseValue.setValue("token", forHTTPHeaderField: "X-Case")
        XCTAssertNotEqual(try normalized(caseSensitiveValue).key, try normalized(lowercaseValue).key)
    }

    func testRejectsNonabsoluteOrNonHTTPURLsAndURLCredentials() {
        for value in [
            "relative/asset",
            "file:///tmp/not-a-network-cache-request",
            "ftp://media.example/asset",
            "https://name@media.example/asset",
            "https://name:secret@media.example/asset",
            "https://:secret@media.example/asset",
        ] {
            XCTAssertThrowsError(try normalized(request(value)), value) { error in
                XCTAssertEqual(error as? MediaCacheError, .invalidRequest)
            }
        }
        var missingURL = request("https://media.example/missing-url")
        missingURL.url = nil
        XCTAssertThrowsError(try normalized(missingURL)) { error in
            XCTAssertEqual(error as? MediaCacheError, .invalidRequest)
        }
    }

    func testRejectsNonGETAndBothBodyForms() {
        var post = request("https://media.example/method")
        post.httpMethod = "POST"
        var body = request("https://media.example/body")
        body.httpBody = Data()
        var stream = request("https://media.example/stream")
        stream.httpBodyStream = InputStream(data: Data("stream-body".utf8))
        for invalid in [post, body, stream] {
            XCTAssertThrowsError(try normalized(invalid)) { error in
                XCTAssertEqual(error as? MediaCacheError, .invalidRequest)
            }
        }
    }

    func testRejectsCallerRangeConditionalAndConflictingEncodingHeaders() {
        let forbiddenHeaders = [
            ("rAnGe", "bytes=0-1"),
            ("IF-RANGE", "\"etag\""),
            ("If-Match", "\"etag\""),
            ("if-none-match", "\"etag\""),
            ("If-Modified-Since", "Mon, 07 Sep 2026 00:00:00 GMT"),
            ("If-Unmodified-Since", "Mon, 07 Sep 2026 00:00:00 GMT"),
            ("Accept-Encoding", "gzip"),
            ("Accept-Encoding", "identity, gzip"),
        ]
        for (name, value) in forbiddenHeaders {
            var invalid = request("https://media.example/transport-owned-headers")
            invalid.setValue(value, forHTTPHeaderField: name)
            XCTAssertThrowsError(try normalized(invalid), name) { error in
                XCTAssertEqual(error as? MediaCacheError, .invalidRequest)
            }
        }
    }

    func testRejectsEmptyTagsIncludingAnInvalidTagAlongsideAValidOne() throws {
        let valid = CacheTag(rawValue: "valid")
        let invalidSets: [Set<CacheTag>] = [
            [],
            [CacheTag(rawValue: "")],
            [CacheTag(rawValue: " \t\n\r")],
            [valid, CacheTag(rawValue: "\u{2003}\n")],
        ]
        for tags in invalidSets {
            XCTAssertThrowsError(try MediaRequest(request: request("https://media.example/tags"), tags: tags).normalized()) { error in
                XCTAssertEqual(error as? MediaCacheError, .invalidTag)
            }
        }
        let opaqueTags: Set<CacheTag> = [CacheTag(rawValue: "Media"), CacheTag(rawValue: "media"), CacheTag(rawValue: " group/雪 ")]
        try MediaRequest.validate(tags: opaqueTags)
        XCTAssertEqual(opaqueTags.count, 3, "Tags are opaque, case-sensitive values rather than normalized paths")
    }

    func testConcurrentReleaseRelinquishesOnceAndRejectsFurtherValidation() async throws {
        let owner = LeaseProbe()
        let file = lease(owner: owner)
        try await file.checkValidity()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { await file.release() }
            }
        }
        await file.release()
        do {
            try await file.checkValidity()
            XCTFail("Released leases cannot become valid again")
        } catch {
            XCTAssertEqual(error as? MediaCacheError, .invalidated)
        }
        let counts = await owner.counts()
        XCTAssertEqual(counts.releases, 1)
        XCTAssertEqual(counts.validations, 1, "Released leases must not ask the owner to validate or extend them")
    }

    func testOwnerInvalidationAndShutdownErrorsReachLeaseConsumer() async throws {
        for failure in [MediaCacheError.invalidated, .closed] {
            let owner = LeaseProbe()
            let file = lease(owner: owner)
            try await file.checkValidity()
            await owner.failValidation(with: failure)
            do {
                try await file.checkValidity()
                XCTFail("Revoked owner state must reach the consumer")
            } catch {
                XCTAssertEqual(error as? MediaCacheError, failure)
            }
            await file.release()
            let counts = await owner.counts()
            XCTAssertEqual(counts.releases, 1)
        }
    }

    func testReleaseDuringSuspendedValidationCannotReturnAValidLease() async {
        let owner = LeaseProbe(suspendsValidation: true)
        let file = lease(owner: owner)
        let validation = Task { try await file.checkValidity() }
        await owner.waitForValidation()
        await file.release()
        await owner.resumeValidation()
        do {
            try await validation.value
            XCTFail("Validation completed after release must fail")
        } catch {
            XCTAssertEqual(error as? MediaCacheError, .invalidated)
        }
        let counts = await owner.counts()
        XCTAssertEqual(counts.releases, 1)
    }

    private func request(_ url: String) -> URLRequest {
        URLRequest(url: URL(string: url)!)
    }

    private func normalized(_ request: URLRequest) throws -> (request: URLRequest, key: String) {
        try MediaRequest(request: request, tags: [CacheTag(rawValue: "request-contract")]).normalized()
    }

    private func lease(owner: LeaseProbe) -> CachedFile {
        CachedFile(
            url: URL(fileURLWithPath: "/unused-cache-contract/\(UUID().uuidString)/payload"),
            key: UUID().uuidString,
            validate: { try await owner.validate() },
            release: { await owner.release() }
        )
    }
}

private actor LeaseProbe {
    private var validationCount = 0
    private var releaseCount = 0
    private var failure: MediaCacheError?
    private let suspendsValidation: Bool
    private var validationContinuation: CheckedContinuation<Void, Never>?
    private var validationStarted: CheckedContinuation<Void, Never>?

    init(suspendsValidation: Bool = false) {
        self.suspendsValidation = suspendsValidation
    }

    func validate() async throws {
        validationCount += 1
        if suspendsValidation {
            await withCheckedContinuation { continuation in
                validationContinuation = continuation
                validationStarted?.resume()
                validationStarted = nil
            }
        }
        if let failure { throw failure }
    }

    func waitForValidation() async {
        guard validationContinuation == nil else { return }
        await withCheckedContinuation { validationStarted = $0 }
    }

    func resumeValidation() {
        validationContinuation?.resume()
        validationContinuation = nil
    }

    func failValidation(with error: MediaCacheError) { failure = error }
    func release() { releaseCount += 1 }
    func counts() -> (validations: Int, releases: Int) { (validationCount, releaseCount) }
}
