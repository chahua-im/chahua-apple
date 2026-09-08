import Foundation
import XCTest
@testable import ChahuaMediaCache

final class HTTPRepresentationTests: XCTestCase {
    private let referenceDate = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!

    func testFreshnessUsesLargerOfApparentAgeAndAgePlusResponseDelay() throws {
        let receivedAt = referenceDate.addingTimeInterval(100)
        let sentAt = receivedAt.addingTimeInterval(-2)
        let aged = try representation(headers: [
            "Date": "Mon, 07 Sep 2026 12:00:00 GMT", "Age": "120", "Cache-Control": "max-age=200"
        ], sentAt: sentAt, receivedAt: receivedAt)
        XCTAssertEqual(aged.freshUntil.timeIntervalSince(receivedAt), 78, accuracy: 0.001)

        let apparentlyOlder = try representation(headers: [
            "Date": "Mon, 07 Sep 2026 12:00:00 GMT", "Age": "20", "Cache-Control": "max-age=200"
        ], sentAt: sentAt, receivedAt: receivedAt)
        XCTAssertEqual(apparentlyOlder.freshUntil.timeIntervalSince(receivedAt), 100, accuracy: 0.001)
    }

    func testExpiresAccountsForAgeAndMaxAgeTakesPrecedence() throws {
        let receivedAt = referenceDate.addingTimeInterval(30)
        var headers = [
            "Date": "Mon, 07 Sep 2026 12:00:00 GMT", "Expires": "Mon, 07 Sep 2026 12:02:00 GMT"
        ]
        let expires = try representation(headers: headers, receivedAt: receivedAt)
        XCTAssertEqual(expires.freshUntil.timeIntervalSince(receivedAt), 90, accuracy: 0.001)
        headers["Cache-Control"] = "max-age=60"
        let maxAge = try representation(headers: headers, receivedAt: receivedAt)
        XCTAssertEqual(maxAge.freshUntil.timeIntervalSince(receivedAt), 30, accuracy: 0.001)
    }

    func testNoCacheAndUnusableFreshnessNeverInventAFreshLifetime() throws {
        for control in ["no-cache, max-age=3600", "no-cache=\"Set-Cookie, ETag\", max-age=3600",
                        "max-age=-1", "max-age=60, max-age=120", ""] {
            let parsed = try representation(headers: ["Cache-Control": control])
            XCTAssertLessThanOrEqual(parsed.freshUntil, referenceDate, control)
        }
        let badAge = try representation(headers: ["Cache-Control": "max-age=3600", "Age": "invalid"])
        XCTAssertLessThanOrEqual(badAge.freshUntil, referenceDate)
    }

    func testNoStoreAndWildcardVaryDisallowRetentionWithoutConfusingQuotedExtensions() throws {
        XCTAssertFalse(try representation(headers: ["Cache-Control": "private, NO-STORE, max-age=3600"]).retained)
        XCTAssertFalse(try representation(headers: ["Vary": "Accept-Language, *"]).retained)
        XCTAssertTrue(try representation(headers: [
            "Cache-Control": "extension=\"no-store, no-cache\", max-age=\"60\"", "Vary": "Accept"
        ]).retained)
    }

    func testConditionalMetadataKeepsWeakValidatorAndOptionalRepresentationLength() throws {
        let validated = try representation(status: 304, headers: [
            "ETag": "W/\"image-revision\"", "Content-Length": "123", "Cache-Control": "max-age=60"
        ])
        XCTAssertEqual(validated.etag, "W/\"image-revision\"")
        XCTAssertEqual(validated.contentLength, 123)
        XCTAssertEqual(validated.freshUntil.timeIntervalSince(referenceDate), 60, accuracy: 0.001)
        XCTAssertNil(try representation(status: 304, headers: [:]).contentLength)
        XCTAssertNil(try representation(headers: ["ETag": "unquoted"]).etag)
    }

    func testLengthParsingRejectsAmbiguousNegativeAndOverflowedValues() throws {
        XCTAssertEqual(try representation(headers: ["Content-Length": "6, 6"]).contentLength, 6)
        XCTAssertEqual(try representation(headers: ["Content-Length": "0"]).contentLength, 0)
        XCTAssertNil(try representation(headers: [:]).contentLength)
        for length in ["6, 7", "-1", "+6", "", "9223372036854775808"] {
            XCTAssertThrowsError(try representation(headers: ["Content-Length": length])) {
                XCTAssertEqual($0 as? MediaCacheError, .invalidResponse)
            }
        }
    }

    func testOnlyCompleteSuccessAndConditionalValidationStatusesAreAccepted() {
        for status in [204, 206, 301, 401, 403, 404, 416, 503] {
            XCTAssertThrowsError(try representation(status: status, headers: ["Content-Encoding": "gzip"])) {
                XCTAssertEqual($0 as? MediaCacheError, .httpStatus(status))
            }
        }
        XCTAssertThrowsError(try representation(headers: ["Content-Encoding": "gzip"])) {
            XCTAssertEqual($0 as? MediaCacheError, .invalidResponse)
        }
        XCTAssertThrowsError(try representation(headers: ["Content-Range": "bytes 0-5/6"])) {
            XCTAssertEqual($0 as? MediaCacheError, .invalidResponse)
        }
    }

    func testTransportRejectsErrorAndEncodedBodiesBeforePublishingAnyBytes() async {
        let transport = HTTPMediaTransport(protocolClasses: [FixtureURLProtocol.self])
        for (status, headers, failure) in [
            (503, ["Content-Length": "6"], MediaCacheError.httpStatus(503)),
            (200, ["Content-Encoding": "gzip", "Content-Length": "6"], .invalidResponse),
            (200, ["Content-Length": "6, 7"], .invalidResponse)
        ] {
            let url = FixtureURLProtocol.install { fixture in
                fixture.respond(status: status, headers: headers, body: Data("abcdef".utf8))
            }
            let body = HTTPBodyCollector()
            do {
                try await transport.execute(request: URLRequest(url: url), onResponse: { _, _, _ in }, onData: {
                    await body.append($0)
                })
                XCTFail("An unusable HTTP body must fail")
            } catch {
                XCTAssertEqual(error as? MediaCacheError, failure)
            }
            let collected = await body.snapshot()
            XCTAssertEqual(collected.data, Data())
            FixtureURLProtocol.uninstall(url)
        }
        await transport.shutdown()
    }

    func testTransportRejectsTruncatedAndOversizedFullBodies() async {
        let transport = HTTPMediaTransport(protocolClasses: [FixtureURLProtocol.self])
        for length in ["7", "5"] {
            let url = FixtureURLProtocol.install { fixture in
                fixture.respond(headers: ["Content-Length": length], body: Data("abcdef".utf8))
            }
            do {
                try await transport.execute(request: URLRequest(url: url), onResponse: { _, _, _ in }, onData: { _ in })
                XCTFail("A full response must match its advertised length")
            } catch {
                // URLSession may detect a truncated transfer before delegate completion.
                let transportFailure = error as? MediaCacheError == .invalidResponse
                let sessionFailure = (error as? URLError)?.code == .networkConnectionLost
                XCTAssertTrue(transportFailure || sessionFailure, "Unexpected error: \(error)")
            }
            FixtureURLProtocol.uninstall(url)
        }
        await transport.shutdown()
    }

    func testUnknownLengthStreamsExactBytesInBoundedHandoffs() async throws {
        let expected = Data((0..<(2 * 1_048_576 + 17)).map { UInt8(truncatingIfNeeded: $0) })
        let url = FixtureURLProtocol.install { fixture in
            fixture.respond(headers: [:], body: expected)
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let transport = HTTPMediaTransport(protocolClasses: [FixtureURLProtocol.self])
        let body = HTTPBodyCollector()
        do {
            try await transport.execute(request: URLRequest(url: url), onResponse: { _, _, _ in }, onData: {
                await body.append($0)
            })
        } catch {
            await transport.shutdown()
            throw error
        }
        await transport.shutdown()
        let collected = await body.snapshot()
        XCTAssertEqual(collected.data, expected)
        XCTAssertLessThanOrEqual(collected.largestBatch, 1_048_576)
    }

    func testConditionalResponseHasNoBodyDespiteRepresentationContentLength() async throws {
        let url = FixtureURLProtocol.install { fixture in
            fixture.respond(status: 304, headers: ["Content-Length": "123"], body: Data())
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let transport = HTTPMediaTransport(protocolClasses: [FixtureURLProtocol.self])
        let body = HTTPBodyCollector()
        var request = URLRequest(url: url)
        request.setValue("W/\"image-revision\"", forHTTPHeaderField: "If-None-Match")
        do {
            try await transport.execute(request: request, onResponse: { _, _, _ in }, onData: {
                await body.append($0)
            })
        } catch {
            await transport.shutdown()
            throw error
        }
        await transport.shutdown()
        let collected = await body.snapshot()
        XCTAssertEqual(collected.data, Data())
    }

    func testConsumerFailureStopsHandoffsAndReachesExecuteCaller() async {
        let url = FixtureURLProtocol.install { fixture in
            fixture.respond(headers: [:], body: Data(repeating: 7, count: 2 * 1_048_576))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let transport = HTTPMediaTransport(protocolClasses: [FixtureURLProtocol.self])
        let body = HTTPBodyCollector()
        do {
            try await transport.execute(request: URLRequest(url: url), onResponse: { _, _, _ in }, onData: {
                await body.append($0)
                throw MediaCacheError.storageFailure
            })
            XCTFail("A failed store write must stop the producer")
        } catch {
            XCTAssertEqual(error as? MediaCacheError, .storageFailure)
        }
        await transport.shutdown()
        let collected = await body.snapshot()
        XCTAssertEqual(collected.calls, 1)
        XCTAssertLessThanOrEqual(collected.data.count, 1_048_576)
    }

    func testCancellationDrainsSuspendedConsumerBeforeReturning() async {
        let started = expectation(description: "consumer owns a batch")
        let cancelled = expectation(description: "consumer observes cancellation")
        let gate = HTTPCallbackGate()
        let url = FixtureURLProtocol.install { fixture in
            fixture.respond(headers: ["Content-Length": "1"], body: Data([1]))
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let transport = HTTPMediaTransport(protocolClasses: [FixtureURLProtocol.self])
        let task = Task {
            do {
                try await transport.execute(request: URLRequest(url: url), onResponse: { _, _, _ in }, onData: { _ in
                    await withTaskCancellationHandler {
                        await gate.suspend(started: started)
                    } onCancel: {
                        cancelled.fulfill()
                    }
                })
                XCTFail("Cancelled execution must not succeed")
            } catch {
                XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
            }
            let drained = await gate.isReleased
            XCTAssertTrue(drained, "Execution must not return while the consumer still owns its batch")
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        await gate.release()
        await task.value
        await transport.shutdown()
    }

    func testShutdownCancelsActiveResponseAndPermanentlyClosesAdmissions() async {
        let started = expectation(description: "response consumer is suspended")
        let cancelled = expectation(description: "shutdown cancels response consumer")
        let gate = HTTPCallbackGate()
        let url = FixtureURLProtocol.install { fixture in
            fixture.respond(headers: ["Content-Length": "0"], body: Data())
        }
        defer { FixtureURLProtocol.uninstall(url) }
        let transport = HTTPMediaTransport(protocolClasses: [FixtureURLProtocol.self])
        let execution = Task {
            do {
                try await transport.execute(request: URLRequest(url: url), onResponse: { _, _, _ in
                    await withTaskCancellationHandler {
                        await gate.suspend(started: started)
                    } onCancel: {
                        cancelled.fulfill()
                    }
                }, onData: { _ in })
                XCTFail("Shutdown must revoke the active request")
            } catch {
                XCTAssertEqual(error as? MediaCacheError, .closed)
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let shutdown = Task {
            await transport.shutdown()
            let drained = await gate.isReleased
            XCTAssertTrue(drained, "Shutdown must drain the response callback")
        }
        await fulfillment(of: [cancelled], timeout: 5)
        await gate.release()
        await execution.value
        await shutdown.value
        do {
            try await transport.execute(request: URLRequest(url: url), onResponse: { _, _, _ in }, onData: { _ in })
            XCTFail("A closed transport cannot admit another request")
        } catch {
            XCTAssertEqual(error as? MediaCacheError, .closed)
        }
    }

    private func representation(status: Int = 200, headers: [String: String],
                                sentAt: Date? = nil, receivedAt: Date? = nil) throws -> HTTPRepresentation {
        let response = HTTPURLResponse(url: URL(string: "https://images.invalid/avatar")!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        return try HTTPRepresentation(response: response, sentAt: sentAt ?? receivedAt ?? referenceDate,
                                      receivedAt: receivedAt ?? referenceDate)
    }
}

private actor HTTPBodyCollector {
    private var data = Data()
    private var largestBatch = 0
    private var calls = 0

    func append(_ batch: Data) {
        data.append(batch)
        largestBatch = max(largestBatch, batch.count)
        calls += 1
    }

    func snapshot() -> (data: Data, largestBatch: Int, calls: Int) { (data, largestBatch, calls) }
}

private actor HTTPCallbackGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isReleased = false

    func suspend(started: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
            started.fulfill()
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
