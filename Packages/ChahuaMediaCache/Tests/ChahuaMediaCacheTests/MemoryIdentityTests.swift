import Foundation
import XCTest
@testable import ChahuaMediaCache

@MainActor
final class MemoryIdentityTests: XCTestCase {
    private let avatars = CacheTag(rawValue: "avatars")
    private let chat = CacheTag(rawValue: "chatMedia")

    func testIdentifierWaitsForSuccessfulCompleteDelivery() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { requests.append($0) }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache()
        let image = request(url, tags: [avatars])
        XCTAssertNil(cache.cachedContentIdentifier(for: image))

        let acquisition = Task { try await cache.file(for: image) }
        try await eventually { requests.values.count == 1 }
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        // Large chunks let URLSession deliver bytes before the fixture finishes.
        requests.values[0].respond(headers: Self.headers(length: 8192), body: Data(repeating: 0x61, count: 4096), finish: false)
        try await eventually { try await cache.usage().total.cachedBytes == 4096 }
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        requests.values[0].send(Data(repeating: 0x62, count: 4096))
        try await eventually { try await cache.usage().total.cachedBytes == 8192 }
        XCTAssertNil(cache.cachedContentIdentifier(for: image))

        requests.values[0].complete()
        let file = try await acquisition.value
        XCTAssertEqual(cache.cachedContentIdentifier(for: image), file.url.absoluteString)
        await file.release()
        XCTAssertEqual(cache.cachedContentIdentifier(for: image), file.url.absoluteString)
    }

    func testLookupRequiresDurableTagsWithoutRegisteringThem() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install {
            requests.append($0)
            $0.respond(headers: Self.headers(length: 3), body: Data("png".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let directory = temporaryDirectory()
        let cache = try await makeCache(directory: directory)
        let avatar = request(url, tags: [avatars])
        let both = request(url, tags: [avatars, chat])
        let file = try await cache.file(for: avatar)
        XCTAssertNil(cache.cachedContentIdentifier(for: both))
        let before = try await cache.usage()
        XCTAssertNil(before.byTag[chat])

        try await cache.addTags([chat], to: file.key)
        XCTAssertEqual(cache.cachedContentIdentifier(for: both), file.url.absoluteString)
        let profile = CacheTag(rawValue: "profile")
        let profileImage = request(url, tags: [profile])
        XCTAssertNil(cache.cachedContentIdentifier(for: profileImage))
        let joined = try await cache.file(for: profileImage)
        XCTAssertEqual(cache.cachedContentIdentifier(for: profileImage), file.url.absoluteString)
        XCTAssertEqual(joined.url, file.url)
        XCTAssertEqual(requests.values.count, 1)
        await file.release()
        await joined.release()

        try await cache.shutdown(removingFiles: false)
        let reopened = try await makeCache(directory: directory)
        let all = request(url, tags: [avatars, chat, profile])
        XCTAssertEqual(reopened.cachedContentIdentifier(for: all), file.url.absoluteString)
        let usage = try await reopened.usage()
        XCTAssertEqual(usage.byTag[profile]?.cachedBytes, 3)
        XCTAssertEqual(usage.byTag[chat]?.cachedBytes, 3)
        XCTAssertEqual(requests.values.count, 1)
    }

    func testIdentifierUsesNormalizedHeadersAndQueryWithoutPrivateKeyAliasing() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install {
            requests.append($0)
            $0.respond(headers: Self.headers(length: 3), body: Data("png".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache()
        var original = URLRequest(url: url)
        original.setValue("fixture-a", forHTTPHeaderField: "Authorization")
        let image = MediaRequest(request: original, tags: [avatars])
        let first = try await cache.file(for: image)

        var fragmentURL = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        fragmentURL.fragment = "thumbnail"
        var normalizedEquivalent = URLRequest(url: try XCTUnwrap(fragmentURL.url))
        normalizedEquivalent.setValue("fixture-a", forHTTPHeaderField: "authorization")
        normalizedEquivalent.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        XCTAssertEqual(cache.cachedContentIdentifier(for: MediaRequest(request: normalizedEquivalent, tags: [avatars])), first.url.absoluteString)

        var otherHeader = original
        otherHeader.setValue("fixture-b", forHTTPHeaderField: "Authorization")
        let otherIdentity = MediaRequest(request: otherHeader, tags: [avatars])
        var otherQuery = original
        otherQuery.url = url.appending(queryItems: [URLQueryItem(name: "revision", value: "2")])
        let revisedImage = MediaRequest(request: otherQuery, tags: [avatars])
        XCTAssertNil(cache.cachedContentIdentifier(for: otherIdentity))
        XCTAssertNil(cache.cachedContentIdentifier(for: revisedImage))
        XCTAssertNil(cache.cachedContentIdentifier(for: MediaRequest(request: original, tags: [])))
        XCTAssertEqual(requests.values.count, 1)

        let privateFile = try await cache.file(for: otherIdentity)
        let revisedFile = try await cache.file(for: revisedImage)
        XCTAssertEqual(cache.cachedContentIdentifier(for: otherIdentity), privateFile.url.absoluteString)
        XCTAssertEqual(cache.cachedContentIdentifier(for: revisedImage), revisedFile.url.absoluteString)
        XCTAssertNotEqual(privateFile.url, first.url)
        XCTAssertNotEqual(revisedFile.url, first.url)
        XCTAssertNotEqual(privateFile.url, revisedFile.url)
        await first.release()
        await privateFile.release()
        await revisedFile.release()
    }

    func testExpiryRevalidationAndReplacementPublishOnlyCurrentFreshGeneration() async throws {
        let requests = FixtureRequests()
        let clock = FixtureClock()
        let url = FixtureURLProtocol.install { requests.append($0) }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(clock: clock)
        let image = request(url, tags: [avatars])
        let initial = Task { try await cache.file(for: image) }
        try await eventually { requests.values.count == 1 }
        requests.values[0].respond(headers: Self.headers(length: 3, maxAge: 10), body: Data("old".utf8))
        let original = try await initial.value
        XCTAssertEqual(cache.cachedContentIdentifier(for: image), original.url.absoluteString)

        clock.advance(10)
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        let revalidation = Task { try await cache.file(for: image) }
        try await eventually { requests.values.count == 2 }
        requests.values[1].respond(status: 304, headers: ["Cache-Control": "max-age=10"], body: Data(), finish: false)
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        requests.values[1].complete()
        let validated = try await revalidation.value
        XCTAssertEqual(validated.url, original.url)
        XCTAssertEqual(cache.cachedContentIdentifier(for: image), original.url.absoluteString)

        clock.advance(10)
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        let replacement = Task { try await cache.file(for: image) }
        try await eventually { requests.values.count == 3 }
        requests.values[2].respond(headers: Self.headers(length: 4096), body: Data(repeating: 0x63, count: 4096), finish: false)
        try await eventually {
            let usage = try await cache.usage()
            return usage.total.itemCount == 2 && usage.total.cachedBytes == 4099
        }
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        XCTAssertEqual(cache.cachedContentIdentifier(for: image, allowingStale: true), original.url.absoluteString)
        requests.values[2].complete()
        let replaced = try await replacement.value
        XCTAssertNotEqual(replaced.url, original.url)
        XCTAssertEqual(cache.cachedContentIdentifier(for: image), replaced.url.absoluteString)
        await assertError(.invalidated) { try await original.checkValidity() }
        await original.release()
        await validated.release()
        XCTAssertEqual(cache.cachedContentIdentifier(for: image), replaced.url.absoluteString)
        await replaced.release()
    }

    func testFailedRevalidationNeverRestoresStaleIdentifier() async throws {
        let requests = FixtureRequests()
        let clock = FixtureClock()
        let url = FixtureURLProtocol.install {
            requests.append($0)
            if requests.values.count == 1 {
                $0.respond(headers: Self.headers(length: 3, maxAge: 10), body: Data("old".utf8))
            } else {
                $0.respond(status: 503, headers: ["Content-Length": "0"], body: Data())
            }
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(clock: clock)
        let image = request(url, tags: [avatars])
        let original = try await cache.file(for: image)
        clock.advance(10)
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        await assertError(.httpStatus(503)) { _ = try await cache.file(for: image) }
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        XCTAssertEqual(cache.cachedContentIdentifier(for: image, allowingStale: true), original.url.absoluteString)
        await original.release()
    }

    func testExplicitRemovalRevokesLiveIdentifierAndOldLeaseCannotEraseReplacement() async throws {
        let url = FixtureURLProtocol.install {
            $0.respond(headers: Self.headers(length: 3), body: Data("png".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache()
        let image = request(url, tags: [avatars, chat])
        let file = try await cache.file(for: image)
        let removal = Task { try await cache.remove(tag: avatars) }
        try await eventually { cache.cachedContentIdentifier(for: image) == nil }
        _ = try await removal.value
        XCTAssertNil(cache.cachedContentIdentifier(for: request(url, tags: [chat])))
        await assertError(.invalidated) { try await file.checkValidity() }

        let replacement = try await cache.file(for: image)
        XCTAssertNotEqual(replacement.url, file.url)
        await file.release()
        XCTAssertEqual(cache.cachedContentIdentifier(for: image), replacement.url.absoluteString)
        _ = try await cache.removeAll()
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        await replacement.release()
    }

    func testLookupDoesNotKeepIdleGenerationLeasedAgainstTrim() async throws {
        let url = FixtureURLProtocol.install {
            $0.respond(headers: Self.headers(length: 3), body: Data("png".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache()
        let image = request(url, tags: [avatars])
        let file = try await cache.file(for: image)
        XCTAssertEqual(cache.cachedContentIdentifier(for: image), file.url.absoluteString)
        _ = try await cache.trim(toDiskBytes: 0)
        XCTAssertEqual(cache.cachedContentIdentifier(for: image), file.url.absoluteString)
        await file.release()
        XCTAssertEqual(cache.cachedContentIdentifier(for: image), file.url.absoluteString)
        _ = try await cache.trim(toDiskBytes: 0)
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
    }

    func testNoStoreNeverPublishesIdentifierDespiteFreshnessAndLiveLease() async throws {
        let url = FixtureURLProtocol.install {
            $0.respond(headers: ["Content-Length": "3", "Content-Type": "image/png", "Cache-Control": "no-store, max-age=3600"], body: Data("png".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache()
        let image = request(url, tags: [avatars])
        let file = try await cache.file(for: image)
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        try await cache.addTags([chat], to: file.key)
        XCTAssertNil(cache.cachedContentIdentifier(for: request(url, tags: [chat])))
        let next = try await cache.file(for: image)
        XCTAssertNotEqual(next.url, file.url)
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        await file.release()
        await next.release()
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
    }

    func testShutdownClosesLookupWhileKeepingDurableFiles() async throws {
        let url = FixtureURLProtocol.install {
            $0.respond(headers: Self.headers(length: 3), body: Data("png".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache()
        let image = request(url, tags: [avatars])
        let file = try await cache.file(for: image)
        let shutdown = Task { try await cache.shutdown(removingFiles: false) }
        try await eventually { cache.cachedContentIdentifier(for: image) == nil }
        await assertError(.closed) { try await file.checkValidity() }
        try await shutdown.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        await file.release()
    }

    func testStorageFailureClosesLookupForUnrelatedFreshGeneration() async throws {
        let url = FixtureURLProtocol.install {
            $0.respond(headers: Self.headers(length: 3), body: Data("png".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache()
        let image = request(url, tags: [avatars])
        let other = request(url.appending(queryItems: [URLQueryItem(name: "other", value: "1")]), tags: [chat])
        let file = try await cache.file(for: image)
        let survivor = try await cache.file(for: other)
        let keyDirectory = file.url.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: keyDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: keyDirectory.path) }
        XCTAssertEqual(cache.cachedContentIdentifier(for: other), survivor.url.absoluteString)
        do {
            _ = try await cache.remove(tag: avatars)
            XCTFail("Removal unexpectedly succeeded in a read-only entry directory")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        XCTAssertNil(cache.cachedContentIdentifier(for: other))
        await file.release()
        await survivor.release()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ChahuaMemoryIdentityTests-\(UUID().uuidString)")
    }

    private func makeCache(directory: URL? = nil, clock: FixtureClock = FixtureClock()) async throws -> MediaCache {
        let directory = directory ?? temporaryDirectory()
        let cache = try await MediaCache(configuration: CacheConfiguration(directory: directory), protocolClasses: [FixtureURLProtocol.self], clock: { clock.now() })
        addTeardownBlock {
            try? await cache.shutdown(removingFiles: true)
            try? FileManager.default.removeItem(at: directory)
        }
        return cache
    }

    private func request(_ url: URL, tags: Set<CacheTag>) -> MediaRequest {
        MediaRequest(request: URLRequest(url: url), tags: tags)
    }

    nonisolated private static func headers(length: Int, maxAge: Int = 3600) -> [String: String] {
        ["Content-Length": String(length), "Content-Type": "image/png", "Cache-Control": "max-age=\(maxAge)", "ETag": "\"a\""]
    }

    private func eventually(_ predicate: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true", file: file, line: line)
        throw URLError(.timedOut)
    }

    private func assertError(_ expected: MediaCacheError, file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? MediaCacheError, expected, file: file, line: line) }
    }
}
