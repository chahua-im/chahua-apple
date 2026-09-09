import Foundation
import XCTest
@testable import ChahuaMediaCache

@MainActor
final class MediaCacheTests: XCTestCase {
    private let avatars = CacheTag(rawValue: "avatars")
    private let chat = CacheTag(rawValue: "chatMedia")

    func testTagsShareFreshBytesAcrossRestartAndClearingEitherEvictsWholeImage() async throws {
        let requests = FixtureRequests()
        let body = Data("abcdef".utf8)
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            fixture.respond(headers: Self.headers(length: body.count), body: body)
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let directory = temporaryDirectory()
        let clock = FixtureClock()
        var cache = try await makeCache(directory, clock: clock)
        let first = try await cache.file(for: request(url, tags: [avatars]))
        let second = try await cache.file(for: request(url, tags: [chat]))
        XCTAssertEqual(try Data(contentsOf: first.url), body)
        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(requests.values.count, 1)
        let usage = try await cache.usage()
        XCTAssertEqual(usage.total.itemCount, 1)
        XCTAssertEqual(usage.total.completeItemCount, 1)
        XCTAssertEqual(usage.total.cachedBytes, 6)
        XCTAssertEqual(usage.byTag[avatars]?.cachedBytes, 6)
        XCTAssertEqual(usage.byTag[chat]?.cachedBytes, 6)
        await first.release()
        await second.release()
        try await cache.shutdown(removingFiles: false)
        cache = try await makeCache(directory, clock: clock)
        let reopened = try await cache.file(for: request(url, tags: [chat]))
        XCTAssertEqual(try Data(contentsOf: reopened.url), body)
        XCTAssertEqual(requests.values.count, 1)
        let removed = try await cache.remove(tag: avatars)
        XCTAssertEqual(removed.removedItemCount, 1)
        XCTAssertEqual(removed.removedCachedBytes, 6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.url.path))
        await assertError(.invalidated) { try await reopened.checkValidity() }
        let empty = try await cache.usage()
        XCTAssertEqual(empty.total.itemCount, 0)
        XCTAssertTrue(empty.byTag.isEmpty)
        let recached = try await cache.file(for: request(url, tags: [chat]))
        XCTAssertNotEqual(recached.url, reopened.url)
        XCTAssertEqual(requests.values.count, 2)
        await recached.release()
        await reopened.release()
        try await cache.shutdown(removingFiles: true)
    }

    func testClearingTaggedZeroByteProducerCancelsEveryJoinedTag() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in requests.append(fixture) }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory())
        let first = Task { try await cache.file(for: request(url, tags: [avatars])) }
        try await eventually { requests.values.count == 1 }
        let second = Task { try await cache.file(for: request(url, tags: [chat])) }
        try await eventually {
            let usage = try await cache.usage()
            return usage.byTag[self.chat]?.itemCount == 1
        }
        let removal = try await cache.remove(tag: avatars)
        XCTAssertEqual(removal.removedItemCount, 1)
        await assertInvalidated(first)
        await assertInvalidated(second)
        try await eventually { requests.values[0].wasCancelled }
        let usage = try await cache.usage()
        XCTAssertEqual(usage.total.cachedBytes, 0)
        XCTAssertEqual(usage.total.itemCount, 0)
        let next = Task { try await cache.file(for: request(url, tags: [chat])) }
        try await eventually { requests.values.count == 2 }
        requests.values[1].respond(headers: Self.headers(length: 3), body: Data("new".utf8))
        let file = try await next.value
        XCTAssertEqual(try Data(contentsOf: file.url), Data("new".utf8))
        await file.release()
        try await cache.shutdown(removingFiles: true)
    }

    func testCancellingOneWaiterDoesNotCancelItsSharedProducer() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in requests.append(fixture) }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory())
        let first = Task { try await cache.file(for: request(url, tags: [avatars])) }
        try await eventually { requests.values.count == 1 }
        let second = Task { try await cache.file(for: request(url, tags: [chat])) }
        try await eventually { try await cache.usage().byTag[self.chat]?.itemCount == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Canceled waiter returned a file") }
        catch is CancellationError { }
        XCTAssertFalse(requests.values[0].wasCancelled)
        let bytes = Data("shared-image".utf8)
        requests.values[0].respond(headers: Self.headers(length: bytes.count), body: bytes)
        let file = try await second.value
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(requests.values.count, 1)
        await file.release()
        try await cache.shutdown(removingFiles: true)
    }

    func testWeakETagRevalidationAfterRestartAndReplacementNeverServesStaleOnError() async throws {
        let requests = FixtureRequests()
        let clock = FixtureClock()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            switch requests.values.count {
            case 1:
                fixture.respond(headers: Self.headers(length: 3, etag: "W/\"old\"", maxAge: 10), body: Data("old".utf8))
            case 2:
                fixture.respond(status: 304, headers: ["Cache-Control": "max-age=10"], body: Data())
            case 3:
                fixture.respond(headers: Self.headers(length: 3, etag: "\"new\"", maxAge: 10), body: Data("new".utf8))
            default:
                fixture.respond(status: 503, headers: ["Content-Length": "5"], body: Data("error".utf8))
            }
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let directory = temporaryDirectory()
        var cache = try await makeCache(directory, clock: clock)
        let first = try await cache.file(for: request(url, tags: [avatars]))
        let originalURL = first.url
        await first.release()
        try await cache.shutdown(removingFiles: false)
        clock.advance(11)
        cache = try await makeCache(directory, clock: clock)
        let validated = try await cache.file(for: request(url, tags: [avatars]))
        XCTAssertEqual(requests.values[1].request.value(forHTTPHeaderField: "If-None-Match"), "W/\"old\"")
        XCTAssertEqual(validated.url, originalURL)
        XCTAssertEqual(try Data(contentsOf: validated.url), Data("old".utf8))
        await validated.release()
        clock.advance(11)
        let replaced = try await cache.file(for: request(url, tags: [avatars]))
        XCTAssertNotEqual(replaced.url, originalURL)
        XCTAssertEqual(try Data(contentsOf: replaced.url), Data("new".utf8))
        await replaced.release()
        clock.advance(11)
        await assertError(.httpStatus(503)) { _ = try await cache.file(for: self.request(url, tags: [self.avatars])) }
        try await cache.shutdown(removingFiles: true)
    }

    func testNoStoreIsPrivateToAcquisitionAndRemovedOnFinalRelease() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            fixture.respond(headers: ["Content-Length": "6", "Cache-Control": "no-store", "Content-Type": "image/png"], body: Data("secret".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory())
        let first = try await cache.file(for: request(url, tags: [avatars]))
        let second = try await cache.file(for: request(url, tags: [chat]))
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(requests.values.count, 2)
        let usage = try await cache.usage()
        XCTAssertEqual(usage.total.itemCount, 2)
        XCTAssertEqual(usage.total.cachedBytes, 12)
        XCTAssertGreaterThan(usage.total.transientDiskBytes, 0)
        await first.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try Data(contentsOf: second.url), Data("secret".utf8))
        await second.release()
        let empty = try await cache.usage()
        XCTAssertEqual(empty.total.itemCount, 0)
        try await cache.shutdown(removingFiles: true)
    }

    func testTrimSkipsLeasesButExplicitRemovalRevokesThem() async throws {
        let url = FixtureURLProtocol.install { fixture in
            fixture.respond(headers: Self.headers(length: 16_384), body: Data(repeating: 0x42, count: 16_384))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory(), capacity: 128 * 1024)
        let first = try await cache.file(for: request(url, tags: [avatars]))
        var otherURL = url
        otherURL.append(queryItems: [URLQueryItem(name: "variant", value: "2")])
        let second = try await cache.file(for: request(otherURL, tags: [chat]))
        await first.release()
        let trimmed = try await cache.trim(toDiskBytes: 0)
        XCTAssertEqual(trimmed.removedItemCount, 1)
        XCTAssertGreaterThan(trimmed.remainingAllocatedDiskBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        try await second.checkValidity()
        let removed = try await cache.remove(tag: chat)
        XCTAssertEqual(removed.removedItemCount, 1)
        await assertError(.invalidated) { try await second.checkValidity() }
        let zero = try await cache.remove(tag: chat)
        XCTAssertEqual(zero.removedItemCount, 0)
        await second.release()
        try await cache.shutdown(removingFiles: true)
    }

    func testActiveAdmissionFailsRatherThanExceedingQuota() async throws {
        let url = FixtureURLProtocol.install { fixture in
            fixture.respond(headers: Self.headers(length: 262_144), body: Data(repeating: 0x55, count: 262_144))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory(), capacity: 65_536)
        await assertError(.quotaExceeded) { _ = try await cache.file(for: self.request(url, tags: [self.avatars])) }
        let usage = try await cache.usage()
        XCTAssertEqual(usage.total.itemCount, 0)
        XCTAssertLessThanOrEqual(usage.total.allocatedDiskBytes + usage.overheadDiskBytes, 65_536)
        try await cache.shutdown(removingFiles: true)
    }

    func testMissingPayloadIsRepairedAsMissAndShutdownReleasesOwner() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            fixture.respond(headers: Self.headers(length: 3), body: Data("png".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let directory = temporaryDirectory()
        let cache = try await makeCache(directory)
        let first = try await cache.file(for: request(url, tags: [avatars]))
        await first.release()
        try FileManager.default.removeItem(at: first.url)
        let usage = try await cache.usage()
        XCTAssertEqual(usage.total.itemCount, 0)
        let second = try await cache.file(for: request(url, tags: [avatars]))
        XCTAssertEqual(requests.values.count, 2)
        XCTAssertEqual(try Data(contentsOf: second.url), Data("png".utf8))
        try await cache.shutdown(removingFiles: false)
        await assertError(.closed) { try await second.checkValidity() }
        await assertError(.closed) { _ = try await cache.usage() }
        let reopened = try await makeCache(directory)
        let third = try await reopened.file(for: request(url, tags: [avatars]))
        XCTAssertEqual(requests.values.count, 2)
        await third.release()
        await second.release()
        try await reopened.shutdown(removingFiles: true)
    }

    func testShutdownCancelsInFlightWorkWithoutRepopulation() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in requests.append(fixture) }
        defer { FixtureURLProtocol.uninstall(url) }
        let directory = temporaryDirectory()
        let cache = try await makeCache(directory)
        let acquisition = Task { try await cache.file(for: request(url, tags: [avatars])) }
        try await eventually { requests.values.count == 1 }
        try await cache.shutdown(removingFiles: false)
        do { _ = try await acquisition.value; XCTFail("Closed cache delivered a file") }
        catch MediaCacheError.closed { }
        catch MediaCacheError.invalidated { }
        catch is CancellationError { }
        let reopened = try await makeCache(directory)
        let usage = try await reopened.usage()
        XCTAssertEqual(usage.total.itemCount, 0)
        try await reopened.shutdown(removingFiles: true)
    }

    func testUnknownLengthCompletesButTruncatedAndEncodedBodiesAreRejected() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            switch fixture.request.url?.query {
            case "truncated": fixture.respond(headers: Self.headers(length: 20), body: Data("short".utf8))
            case "encoded": fixture.respond(headers: ["Content-Length": "3", "Content-Encoding": "gzip"], body: Data("bad".utf8))
            case "empty": fixture.respond(headers: Self.headers(length: 0), body: Data())
            default: fixture.respond(headers: ["Cache-Control": "max-age=3600", "Content-Type": "image/png"], body: Data("unknown-length".utf8))
            }
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory())
        let file = try await cache.file(for: request(url, tags: [avatars]))
        XCTAssertEqual(try Data(contentsOf: file.url), Data("unknown-length".utf8))
        await file.release()
        for query in ["truncated", "encoded"] {
            let bad = URL(string: url.absoluteString + "?" + query)!
            await assertError(.invalidResponse) { _ = try await cache.file(for: self.request(bad, tags: [self.chat])) }
        }
        let empty = try await cache.file(for: request(URL(string: url.absoluteString + "?empty")!, tags: [chat]))
        XCTAssertEqual(try Data(contentsOf: empty.url), Data())
        await empty.release()
        try await cache.shutdown(removingFiles: true)
    }

    func testConcurrentTagUpdatesSurviveConditionalGenerationTransfer() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            if requests.values.count == 1 {
                fixture.respond(headers: Self.headers(length: 3, maxAge: 0), body: Data("png".utf8))
            } else {
                fixture.respond(status: 304, headers: ["Cache-Control": "max-age=3600"], body: Data())
            }
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory())
        let first = try await cache.file(for: request(url, tags: [avatars]))
        let key = first.key
        await first.release()
        let acquisition = Task { try await cache.file(for: request(url, tags: [chat])) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 32 {
                group.addTask {
                    try await cache.addTags([CacheTag(rawValue: "tag-\(index)")], to: key)
                }
            }
            try await group.waitForAll()
        }
        let second = try await acquisition.value
        let usage = try await cache.usage()
        for index in 0 ..< 32 {
            XCTAssertEqual(usage.byTag[CacheTag(rawValue: "tag-\(index)")]?.cachedBytes, 3)
        }
        XCTAssertEqual(usage.total.itemCount, 1)
        XCTAssertEqual(requests.values.count, 2)
        await second.release()
        try await cache.shutdown(removingFiles: true)
    }

    func testNoStoreRevalidationStorageFailureCannotRestoreRetainedLookup() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            if requests.values.count == 1 {
                fixture.respond(headers: Self.headers(length: 3, maxAge: 0), body: Data("png".utf8))
            } else {
                fixture.respond(status: 304, headers: ["Cache-Control": "no-store"], body: Data())
            }
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory())
        let original = try await cache.file(for: request(url, tags: [avatars]))
        let generation = original.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: generation.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: generation.path)
        }
        do {
            _ = try await cache.file(for: request(url, tags: [chat]))
            XCTFail("Failed transient-marker persistence delivered retained data")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        await assertError(.invalidated) { try await original.checkValidity() }
        do {
            _ = try await cache.file(for: request(url, tags: [chat]))
            XCTFail("Unavailable retained generation was admitted again")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertEqual(requests.values.count, 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: generation.path)
        await original.release()
        try await cache.shutdown(removingFiles: true)
    }

    func testCacheOnlyStaleReadSurvivesSuspendedReplacementAndRegistersTagsDurably() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            if requests.values.count == 1 {
                fixture.respond(headers: Self.headers(length: 3, maxAge: 0), body: Data("old".utf8))
            }
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let directory = temporaryDirectory()
        let cache = try await makeCache(directory)
        let image = request(url, tags: [avatars])
        let missing = try await cache.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(missing)
        XCTAssertTrue(requests.values.isEmpty)
        let raw = try await cache.file(for: image)
        let freshOnly = try await cache.cachedFile(for: image)
        XCTAssertNil(freshOnly)
        let cached = try await cache.cachedFile(for: image, allowingStale: true)
        let old = try XCTUnwrap(cached)
        XCTAssertEqual(try Data(contentsOf: old.url), Data("old".utf8))
        XCTAssertEqual(requests.values.count, 1)

        let refresh = Task { try await cache.file(for: image) }
        try await eventually { requests.values.count == 2 }
        let joinedRequest = request(url, tags: [chat])
        let joinedCached = try await cache.cachedFile(for: joinedRequest, allowingStale: true)
        let joined = try XCTUnwrap(joinedCached)
        XCTAssertEqual(joined.url, old.url)
        XCTAssertEqual(cache.cachedContentIdentifier(for: joinedRequest, allowingStale: true), old.url.absoluteString)
        requests.values[1].respond(headers: Self.headers(length: 8192), body: Data(repeating: 0x62, count: 4096), finish: false)
        try await eventually { try await cache.usage().total.cachedBytes == 4099 }
        try await old.checkValidity()
        await assertError(.invalidated) { try await raw.checkValidity() }
        let during = try await cache.cachedFile(for: image, allowingStale: true)
        XCTAssertEqual(during?.url, old.url)
        await during?.release()
        requests.values[1].send(Data(repeating: 0x63, count: 4096))
        requests.values[1].complete()
        let new = try await refresh.value
        XCTAssertNotEqual(new.url, old.url)
        XCTAssertEqual(cache.cachedContentIdentifier(for: joinedRequest), new.url.absoluteString)
        try await old.checkValidity()
        XCTAssertEqual(try Data(contentsOf: old.url), Data("old".utf8))
        await old.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: joined.url.path))
        await joined.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: joined.url.path))
        await raw.release()
        await new.release()
        try await cache.shutdown(removingFiles: false)
        let reopened = try await makeCache(directory)
        let recovered = try await reopened.cachedFile(for: joinedRequest)
        XCTAssertEqual(recovered?.url, new.url)
        XCTAssertEqual(requests.values.count, 2)
        await recovered?.release()
        _ = try await reopened.remove(tag: chat)
        let removed = try await reopened.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(removed)
    }

    func testFailedReplacementRetainsStalePayloadAcrossRecovery() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            if requests.values.count == 1 {
                fixture.respond(headers: Self.headers(length: 3, maxAge: 0), body: Data("old".utf8))
            } else {
                fixture.respond(headers: Self.headers(length: 100), body: Data("short".utf8))
            }
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let directory = temporaryDirectory()
        let cache = try await makeCache(directory)
        let image = request(url, tags: [avatars])
        let original = try await cache.file(for: image)
        await original.release()
        await assertError(.invalidResponse) { _ = try await cache.file(for: image) }
        let stale = try await cache.cachedFile(for: image, allowingStale: true)
        XCTAssertEqual(stale?.url, original.url)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(stale).url), Data("old".utf8))
        XCTAssertNil(cache.cachedContentIdentifier(for: image))
        XCTAssertEqual(cache.cachedContentIdentifier(for: image, allowingStale: true), original.url.absoluteString)
        await stale?.release()
        try await cache.shutdown(removingFiles: false)
        let reopened = try await makeCache(directory)
        let recovered = try await reopened.cachedFile(for: image, allowingStale: true)
        XCTAssertEqual(recovered?.url, original.url)
        XCTAssertEqual(requests.values.count, 2)
        await recovered?.release()
    }

    func testStalePolicyRestrictionsSurviveRecoveryAndHeaderless304() async throws {
        for policy in ["no-cache", "must-revalidate", "no-store"] {
            let requests = FixtureRequests()
            let url = FixtureURLProtocol.install { fixture in
                requests.append(fixture)
                if requests.values.count == 1 {
                    fixture.respond(headers: ["Content-Length": "3", "ETag": "\"old\"", "Cache-Control": policy], body: Data("old".utf8))
                } else {
                    fixture.respond(status: 304, headers: [:], body: Data())
                }
            }
            defer { FixtureURLProtocol.uninstall(url) }
            let directory = temporaryDirectory()
            let cache = try await makeCache(directory)
            let image = request(url, tags: [avatars])
            let original = try await cache.file(for: image)
            let denied = try await cache.cachedFile(for: image, allowingStale: true)
            XCTAssertNil(denied, policy)
            XCTAssertNil(cache.cachedContentIdentifier(for: image, allowingStale: true), policy)
            await original.release()
            try await cache.shutdown(removingFiles: false)
            let reopened = try await makeCache(directory)
            let afterRecovery = try await reopened.cachedFile(for: image, allowingStale: true)
            XCTAssertNil(afterRecovery, policy)
            if policy != "no-store" {
                let validated = try await reopened.file(for: image)
                XCTAssertEqual(validated.url, original.url)
                await validated.release()
                try await reopened.shutdown(removingFiles: false)
                let again = try await makeCache(directory)
                let after304 = try await again.cachedFile(for: image, allowingStale: true)
                XCTAssertNil(after304, policy)
                XCTAssertNil(again.cachedContentIdentifier(for: image, allowingStale: true), policy)
                XCTAssertEqual(requests.values.count, 2)
            } else {
                XCTAssertEqual(requests.values.count, 1)
            }
        }
    }

    func testLegacyMetadataRequiresKnownPolicyBeforeStaleReads() async throws {
        let requests = FixtureRequests()
        let clock = FixtureClock()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            if requests.values.count == 1 {
                fixture.respond(headers: Self.headers(length: 3, maxAge: 10), body: Data("old".utf8))
            } else if requests.values.count == 2 {
                fixture.respond(status: 304, headers: [:], body: Data())
            } else {
                fixture.respond(headers: ["Content-Length": "3"], body: Data("new".utf8))
            }
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let directory = temporaryDirectory()
        let cache = try await makeCache(directory, clock: clock)
        let image = request(url, tags: [avatars])
        let original = try await cache.file(for: image)
        await original.release()
        try await cache.shutdown(removingFiles: false)
        let metadata = original.url.deletingLastPathComponent().appendingPathComponent("metadata.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        json.removeValue(forKey: "requiresRevalidation")
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)
        let reopened = try await makeCache(directory, clock: clock)
        let fresh = try await reopened.cachedFile(for: image)
        XCTAssertEqual(fresh?.url, original.url)
        await fresh?.release()
        clock.advance(11)
        let expired = try await reopened.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(expired)
        let headerless304 = try await reopened.file(for: image)
        await headerless304.release()
        let stillUnknown = try await reopened.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(stillUnknown)
        let replacement = try await reopened.file(for: image)
        await replacement.release()
        let known = try await reopened.cachedFile(for: image, allowingStale: true)
        XCTAssertEqual(known?.url, replacement.url)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(known).url), Data("new".utf8))
        XCTAssertEqual(requests.values.count, 3)
        await known?.release()
    }

    func testCacheOnlyCorruptionAndExplicitRemovalRevokeWithoutHTTP() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            fixture.respond(headers: Self.headers(length: 3, maxAge: 0), body: Data("old".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory())
        let image = request(url, tags: [avatars])
        let original = try await cache.file(for: image)
        let cached = try await cache.cachedFile(for: image, allowingStale: true)
        let stale = try XCTUnwrap(cached)
        try FileManager.default.removeItem(at: original.url)
        let corrupt = try await cache.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(corrupt)
        XCTAssertNil(cache.cachedContentIdentifier(for: image, allowingStale: true))
        await assertError(.invalidated) { try await stale.checkValidity() }
        XCTAssertEqual(requests.values.count, 1)
        await original.release()
        await stale.release()
        let replacement = try await cache.file(for: image)
        let nextCached = try await cache.cachedFile(for: image, allowingStale: true)
        let next = try XCTUnwrap(nextCached)
        _ = try await cache.remove(tag: avatars)
        await assertError(.invalidated) { try await next.checkValidity() }
        let removed = try await cache.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(removed)
        XCTAssertEqual(requests.values.count, 2)
        await next.release()
        await replacement.release()
    }

    func testInvalidationsReachEverySubscriberWithoutRevokingOrdinaryReplacementOrNoStoreRelease() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            fixture.respond(headers: ["Content-Length": "3", "Cache-Control": requests.values.count == 3 ? "no-store" : "max-age=0"],
                            body: Data("png".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory())
        let firstStream = await cache.invalidations()
        let secondStream = await cache.invalidations()
        let firstEvents = Task { var result: [CacheInvalidation] = []; for await event in firstStream { result.append(event) }; return result }
        let secondEvents = Task { var result: [CacheInvalidation] = []; for await event in secondStream { result.append(event) }; return result }
        let image = request(url, tags: [avatars])
        let old = try await cache.file(for: image)
        await old.release()
        let new = try await cache.file(for: image)
        await new.release()
        let transient = try await cache.file(for: image)
        await transient.release()
        _ = try await cache.remove(tag: avatars)
        try await cache.shutdown(removingFiles: true)
        for events in [await firstEvents.value, await secondEvents.value] {
            XCTAssertEqual(events.count, 3)
            guard events.count == 3 else { continue }
            guard case .contentIdentifier(let restrictedID) = events[0] else { XCTFail("Missing HTTP policy revocation"); continue }
            XCTAssertEqual(restrictedID, new.url.absoluteString)
            guard case .tags(let tags) = events[1] else { XCTFail("Missing category revocation"); continue }
            XCTAssertEqual(tags, [avatars])
            guard case .all = events[2] else { XCTFail("Missing shutdown revocation"); continue }
        }
    }

    func testFailedNoStoreReplacementCannotRestorePermissiveStalePolicy() async throws {
        let policy = "no-store"
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            if requests.values.count == 1 {
                fixture.respond(headers: Self.headers(length: 3, maxAge: 0), body: Data("old".utf8))
            }
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let directory = temporaryDirectory()
        let cache = try await makeCache(directory)
        let image = request(url, tags: [avatars])
        let original = try await cache.file(for: image)
        await original.release()
        XCTAssertEqual(cache.cachedContentIdentifier(for: image, allowingStale: true), original.url.absoluteString)
        let refresh = Task { try await cache.file(for: image) }
        try await eventually { requests.values.count == 2 }
        // URLSession buffers tiny fixture responses; deliver a real partial chunk.
        requests.values[1].respond(
            status: 200, headers: ["Cache-Control": policy, "Content-Type": "image/png", "Content-Length": "8192"], body: Data(repeating: 0x6e, count: 4096),
            finish: false)
        try await eventually { cache.cachedContentIdentifier(for: image, allowingStale: true) == nil }
        let during = try await cache.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(during, policy)
        requests.values[1].fail(URLError(.timedOut))
        do { _ = try await refresh.value; XCTFail("Failed refresh returned a file") } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let afterFailure = try await cache.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(afterFailure, policy)
        try await cache.shutdown(removingFiles: false)
        let reopened = try await makeCache(directory)
        let recovered = try await reopened.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(recovered, policy)
        XCTAssertEqual(requests.values.count, 2)
    }

    func testRemovingJoinedStaleTagCancelsRefreshAndCannotRestorePrevious() async throws {
        let requests = FixtureRequests()
        let url = FixtureURLProtocol.install { fixture in
            requests.append(fixture)
            if requests.values.count == 1 {
                fixture.respond(headers: Self.headers(length: 3, maxAge: 0), body: Data("old".utf8))
            }
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let directory = temporaryDirectory()
        let cache = try await makeCache(directory)
        let image = request(url, tags: [avatars])
        let original = try await cache.file(for: image)
        await original.release()
        let refresh = Task { try await cache.file(for: image) }
        try await eventually { requests.values.count == 2 }
        let joined = try await cache.cachedFile(for: request(url, tags: [chat]), allowingStale: true)
        let stale = try XCTUnwrap(joined)
        _ = try await cache.remove(tag: chat)
        await assertInvalidated(refresh)
        await assertError(.invalidated) { try await stale.checkValidity() }
        XCTAssertNil(cache.cachedContentIdentifier(for: image, allowingStale: true))
        let removed = try await cache.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(removed)
        await stale.release()
        try await cache.shutdown(removingFiles: false)
        let reopened = try await makeCache(directory)
        let recovered = try await reopened.cachedFile(for: image, allowingStale: true)
        XCTAssertNil(recovered)
        XCTAssertEqual(requests.values.count, 2)
    }

    func testCorruptionAndEvictionPublishGenerationInvalidations() async throws {
        let url = FixtureURLProtocol.install { fixture in
            fixture.respond(headers: Self.headers(length: 3), body: Data("png".utf8))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let cache = try await makeCache(temporaryDirectory())
        let stream = await cache.invalidations()
        let collected = Task { var events: [CacheInvalidation] = []; for await event in stream { events.append(event) }; return events }
        let image = request(url, tags: [avatars])
        let corrupt = try await cache.file(for: image)
        await corrupt.release()
        try FileManager.default.removeItem(at: corrupt.url)
        let repaired = try await cache.cachedFile(for: image)
        XCTAssertNil(repaired)
        let replacement = try await cache.file(for: image)
        await replacement.release()
        _ = try await cache.trim(toDiskBytes: 0)
        try await cache.shutdown(removingFiles: true)
        let events = await collected.value
        XCTAssertEqual(events.count, 3)
        guard events.count == 3 else { return }
        guard case .contentIdentifier(let corruptedID) = events[0],
              case .contentIdentifier(let evictedID) = events[1],
              case .all = events[2] else {
            XCTFail("Missing generation or shutdown invalidation")
            return
        }
        XCTAssertEqual(corruptedID, corrupt.url.absoluteString)
        XCTAssertEqual(evictedID, replacement.url.absoluteString)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ChahuaImageCacheTests-\(UUID().uuidString)")
    }
    private func makeCache(_ directory: URL, clock: FixtureClock = FixtureClock(), capacity: Int64 = 1_073_741_824) async throws -> MediaCache {
        let cache = try await MediaCache(configuration: CacheConfiguration(directory: directory, maximumDiskBytes: capacity), protocolClasses: [FixtureURLProtocol.self], clock: { clock.now() })
        addTeardownBlock {
            try? await cache.shutdown(removingFiles: true)
            try? FileManager.default.removeItem(at: directory)
        }
        return cache
    }
    private func request(_ url: URL, tags: Set<CacheTag>) -> MediaRequest {
        MediaRequest(request: URLRequest(url: url), tags: tags)
    }
    nonisolated private static func headers(length: Int, etag: String = "\"a\"", maxAge: Int = 3600) -> [String: String] {
        ["Content-Length": String(length), "Content-Type": "image/png", "Cache-Control": "max-age=\(maxAge)", "ETag": etag]
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
    private func assertInvalidated(_ task: Task<CachedFile, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Removed producer returned a file", file: file, line: line) }
        catch MediaCacheError.invalidated { }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error \(error)", file: file, line: line) }
    }
}
