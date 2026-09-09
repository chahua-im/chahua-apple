import CoreGraphics
import Foundation
import ImageIO
import Nuke
import UniformTypeIdentifiers
import XCTest
@testable import ChahuaMediaCache
@testable import chahua_apple

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MediaImageLoaderTests: XCTestCase {
    private let avatars = CacheTag(rawValue: "avatars")
    private let chatMedia = CacheTag(rawValue: "chatMedia")

    func testDecodedMemoryHitRegistersTagsAndClearingChangesPixels() async throws {
        let red = try makeMediaPNG(red: 255, green: 0, blue: 0, width: 16, height: 64)
        let fixture = MediaImageFixture(data: red)
        let context = makeContext(fixture: fixture)
        context.activate(uid: 1)
        let resources = try await context.resources(for: context.activationID)
        let size = CGSize(width: 8, height: 8)

        let first = try await resources.images.image(for: request(fixture, tag: avatars), thumbnailPixelSize: size)
        let firstBitmap = try bitmap(first)
        XCTAssertEqual(firstBitmap.width, 8)
        XCTAssertEqual(firstBitmap.height, 32, "An aspect-fill thumbnail must not underdecode portrait avatars")
        XCTAssertEqual(try pixel(first), [255, 0, 0, 255])

        let second = try await resources.images.image(for: request(fixture, tag: chatMedia), thumbnailPixelSize: size)
        XCTAssertEqual(second.cacheType, .memory)
        XCTAssertEqual(try pixel(second), [255, 0, 0, 255])
        XCTAssertEqual(fixture.requestCount, 1)
        let usage = try await resources.cache.usage()
        XCTAssertEqual(usage.total.itemCount, 1)
        XCTAssertEqual(usage.total.cachedBytes, Int64(red.count))
        XCTAssertEqual(usage.byTag[avatars]?.cachedBytes, Int64(red.count))
        XCTAssertEqual(usage.byTag[chatMedia]?.cachedBytes, Int64(red.count))

        _ = try await resources.cache.remove(tag: avatars)
        let cleared = try await resources.cache.usage()
        XCTAssertEqual(cleared.total.itemCount, 0)
        XCTAssertTrue(cleared.byTag.isEmpty)
        fixture.replaceBody(try makeMediaPNG(red: 0, green: 255, blue: 0, width: 16, height: 64))
        let replacement = try await resources.images.image(for: request(fixture, tag: chatMedia), thumbnailPixelSize: size)
        XCTAssertEqual(try pixel(replacement), [0, 255, 0, 255])
        XCTAssertEqual(fixture.requestCount, 2)
        XCTAssertNotEqual(first.request.url, replacement.request.url)
    }

    func testDecodeFailureReleasesLeaseForEviction() async throws {
        let fixture = MediaImageFixture(data: Data("not an image".utf8))
        let context = makeContext(fixture: fixture)
        context.activate(uid: 1)
        let resources = try await context.resources(for: context.activationID)
        do {
            _ = try await resources.images.image(for: request(fixture, tag: avatars))
            XCTFail("Invalid encoded image must fail the real decoder")
        } catch is ImagePipeline.Error {
            // The raw response was valid; only image decoding fails.
        }
        _ = try await resources.cache.trim(toDiskBytes: 0)
        let usage = try await resources.cache.usage()
        XCTAssertEqual(usage.total.itemCount, 0, "Failed decoding must not leave a leased, unevictable entry")
    }

    func testAccountSwitchRejectsDelayedImageAndOldResources() async throws {
        let fixture = MediaImageFixture(
            data: try makeMediaPNG(red: 255, green: 0, blue: 0),
            suspended: true
        )
        let context = makeContext(fixture: fixture)
        context.activate(uid: 7)
        let oldActivation = context.activationID
        let oldResources = try await context.resources(for: oldActivation)
        context.activate(uid: 7)
        XCTAssertEqual(context.activationID, oldActivation)
        let oldRequest = request(fixture, tag: avatars)
        let pendingImage = Task { try await oldResources.images.image(for: oldRequest) }
        for _ in 0 ..< 250 where fixture.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fixture.requestCount, 1)

        context.activate(uid: 8)
        XCTAssertNotEqual(context.activationID, oldActivation)
        XCTAssertFalse(context.isReady)
        do {
            _ = try await context.resources(for: oldActivation)
            XCTFail("A revoked activation must not return account resources")
        } catch {
            XCTAssertEqual(error as? MediaCacheError, .invalidated)
        }
        let newResources = try await context.resources(for: context.activationID)
        do {
            _ = try await pendingImage.value
            XCTFail("A delayed old-account image must not escape closure")
        } catch {
            XCTAssertEqual(error as? MediaCacheError, .closed)
        }
        fixture.replaceBody(try makeMediaPNG(red: 0, green: 0, blue: 255))
        fixture.resume()
        let newImage = try await newResources.images.image(for: request(fixture, tag: avatars))
        XCTAssertEqual(try pixel(newImage), [0, 0, 255, 255])
        let newUsage = try await newResources.cache.usage()
        XCTAssertEqual(newUsage.total.itemCount, 1)
    }

    func testStaleInitializationClosesBeforeSameAccountReopens() async throws {
        let directory = temporaryDirectory()
        let started = expectation(description: "First account store initialized")
        let gate = MediaInitializationGate()
        var openedCaches: [MediaCache] = []
        let context = AppMediaContext(rootDirectory: directory, namespace: "injected") { configuration in
            let cache = try await MediaCache(configuration: configuration, protocolClasses: [MediaImageURLProtocol.self], clock: { Date() })
            openedCaches.append(cache)
            if openedCaches.count == 1 {
                started.fulfill()
                await gate.wait()
            }
            return cache
        }
        registerCleanup(context: context, directory: directory)
        addTeardownBlock { await gate.open() }
        context.activate(uid: 7)
        let firstActivation = context.activationID
        await fulfillment(of: [started], timeout: 5)
        context.activate(uid: 8)
        context.activate(uid: 7)
        await gate.open()
        let resources = try await context.resources(for: context.activationID)
        XCTAssertTrue(context.isReady)
        XCTAssertNotEqual(context.activationID, firstActivation)
        XCTAssertFalse(resources.cache === openedCaches[0])
        do {
            _ = try await openedCaches[0].usage()
            XCTFail("Stale initialization must release its owner lock and close")
        } catch {
            XCTAssertEqual(error as? MediaCacheError, .closed)
        }
    }

    func testNilDirectoryNeverCreatesAccountCache() async {
        var opened = false
        let context = AppMediaContext(rootDirectory: nil, namespace: "injected") { configuration in
            opened = true
            return try await MediaCache(configuration: configuration)
        }
        context.activate(uid: 1)
        do {
            _ = try await context.resources(for: context.activationID)
            XCTFail("Disabled context must not expose network resources")
        } catch {
            XCTAssertEqual(error as? MediaCacheError, .invalidConfiguration)
        }
        XCTAssertFalse(opened)
        XCTAssertFalse(context.isReady)
    }

    func testDiskWarmExpiredImageEmitsBeforeRefreshAndRawCallerStillWaits() async throws {
        let clock = MediaImageClock()
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 0))
        let context = makeContext(fixture: fixture, clock: { clock.now() })
        context.activate(uid: 1)
        let resources = try await context.resources(for: context.activationID)
        let mediaRequest = request(fixture, tag: avatars)
        let file = try await resources.cache.file(for: mediaRequest)
        await file.release()
        clock.advance(by: 3601)
        XCTAssertNil(resources.images.cachedImage(for: mediaRequest), "Only the raw file was warmed.")
        fixture.replaceBody(try makeMediaPNG(red: 0, green: 255, blue: 0))
        fixture.suspend()
        defer { fixture.resume() }
        let emitted = expectation(description: "Expired file decoded before HTTP completes")
        var cached: ImageResponse?
        let presentation = Task {
            try await resources.images.image(for: mediaRequest) { response in
                cached = response
                emitted.fulfill()
            }
        }
        defer { presentation.cancel() }
        var rawFinished = false
        let raw = Task {
            let response = try await resources.images.image(for: mediaRequest)
            rawFinished = true
            return response
        }
        defer { raw.cancel() }
        await fulfillment(of: [emitted], timeout: 5)
        XCTAssertEqual(try pixel(XCTUnwrap(cached)), [255, 0, 0, 255])
        for _ in 0 ..< 250 where fixture.requestCount < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fixture.requestCount, 2)
        XCTAssertFalse(rawFinished, "The raw image API must still wait for freshness.")
        fixture.resume()
        let refreshed = try await presentation.value
        let freshRaw = try await raw.value
        XCTAssertEqual(try pixel(refreshed), [0, 255, 0, 255])
        XCTAssertEqual(try pixel(freshRaw), [0, 255, 0, 255])
        XCTAssertEqual(fixture.requestCount, 2, "Both image paths must join one refresh producer.")
    }

    func testFailedRefreshLeavesExpiredImageEligibleForPresentation() async throws {
        let clock = MediaImageClock()
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 0))
        let context = makeContext(fixture: fixture, clock: { clock.now() })
        context.activate(uid: 1)
        let resources = try await context.resources(for: context.activationID)
        let mediaRequest = request(fixture, tag: avatars)
        _ = try await resources.images.image(for: mediaRequest)
        clock.advance(by: 3601)
        fixture.fail(with: .notConnectedToInternet)
        var cached: ImageResponse?
        do {
            _ = try await resources.images.image(for: mediaRequest) { cached = $0 }
            XCTFail("The freshness acquisition must report the real network failure.")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(try pixel(XCTUnwrap(cached)), [255, 0, 0, 255])
        let retained = try XCTUnwrap(resources.images.cachedImage(for: mediaRequest))
        XCTAssertEqual(try pixel(retained), [255, 0, 0, 255])
        _ = try await resources.cache.remove(tag: avatars)
        XCTAssertNil(resources.images.cachedImage(for: mediaRequest),
                     "Failure retention must not override explicit revocation.")
    }

    func testNoCacheResponseNeverEmitsAnUnvalidatedFirstFrame() async throws {
        let fixture = MediaImageFixture(
            data: try makeMediaPNG(red: 255, green: 0, blue: 0),
            cacheControl: "no-cache, max-age=3600"
        )
        let context = makeContext(fixture: fixture)
        context.activate(uid: 1)
        let resources = try await context.resources(for: context.activationID)
        let mediaRequest = request(fixture, tag: avatars)
        _ = try await resources.images.image(for: mediaRequest)
        XCTAssertNil(resources.images.cachedImage(for: mediaRequest))
        fixture.replaceBody(try makeMediaPNG(red: 0, green: 255, blue: 0))
        fixture.suspend()
        defer { fixture.resume() }
        var emitted = false
        let presentation = Task {
            try await resources.images.image(for: mediaRequest) { _ in emitted = true }
        }
        defer { presentation.cancel() }
        for _ in 0 ..< 250 where fixture.requestCount < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fixture.requestCount, 2)
        XCTAssertFalse(emitted)
        fixture.resume()
        let refreshed = try await presentation.value
        XCTAssertEqual(try pixel(refreshed), [0, 255, 0, 255])
        XCTAssertFalse(emitted)
    }

    private func makeContext(
        fixture: MediaImageFixture, clock: @escaping @Sendable () -> Date = { Date() }
    ) -> AppMediaContext {
        let directory = temporaryDirectory()
        MediaImageURLProtocol.install(fixture)
        let context = AppMediaContext(rootDirectory: directory, namespace: "injected") { configuration in
            try await MediaCache(configuration: configuration, protocolClasses: [MediaImageURLProtocol.self], clock: clock)
        }
        registerCleanup(context: context, directory: directory, fixture: fixture)
        return context
    }

    private func registerCleanup(context: AppMediaContext, directory: URL, fixture: MediaImageFixture? = nil) {
        addTeardownBlock {
            let activation = await MainActor.run {
                context.activate(uid: nil)
                return context.activationID
            }
            _ = try? await context.resources(for: activation)
            if let fixture { MediaImageURLProtocol.remove(fixture) }
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MediaImageTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func request(_ fixture: MediaImageFixture, tag: CacheTag) -> MediaRequest {
        MediaRequest(request: URLRequest(url: fixture.url), tags: [tag])
    }

    private func bitmap(_ response: ImageResponse) throws -> CGImage {
        #if os(macOS)
        try XCTUnwrap(response.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #else
        try XCTUnwrap(response.image.cgImage)
        #endif
    }

    private func pixel(_ response: ImageResponse) throws -> [UInt8] {
        let image = try bitmap(response)
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}

private actor MediaInitializationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

func makeMediaPNG(red: UInt8, green: UInt8, blue: UInt8, width: Int = 16, height: Int = 16) throws -> Data {
    let context = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 components: [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

final class MediaImageFixture: @unchecked Sendable {
    struct Response: Sendable {
        let data: Data
        let cacheControl: String
    }

    let url = URL(string: "https://image.invalid/\(UUID().uuidString).png")!
    private let lock = NSLock()
    private var body: Data
    private var suspended: Bool
    private let cacheControl: String
    private var failure: URLError.Code?
    private var count = 0
    private var pending: [UUID: @Sendable (Result<Response, URLError>) -> Void] = [:]
    private let onRequest: (@Sendable () -> Void)?

    init(
        data: Data, cacheControl: String = "max-age=3600", suspended: Bool = false,
        onRequest: (@Sendable () -> Void)? = nil
    ) {
        body = data
        self.suspended = suspended
        self.cacheControl = cacheControl
        self.onRequest = onRequest
    }

    var requestCount: Int { lock.withLock { count } }

    func replaceBody(_ data: Data) { lock.withLock { body = data } }

    func suspend() { lock.withLock { suspended = true } }

    func fail(with code: URLError.Code) { lock.withLock { failure = code } }

    private func response() -> Result<Response, URLError> {
        if let failure { return .failure(URLError(failure)) }
        return .success(Response(data: body, cacheControl: cacheControl))
    }

    func resume() {
        let (callbacks, result) = lock.withLock {
            suspended = false
            let callbacks = Array(pending.values)
            pending.removeAll()
            return (callbacks, response())
        }
        for callback in callbacks { callback(result) }
    }

    fileprivate func begin(id: UUID, completion: @escaping @Sendable (Result<Response, URLError>) -> Void) {
        let result: Result<Response, URLError>? = lock.withLock {
            count += 1
            if suspended {
                pending[id] = completion
                return nil
            }
            return response()
        }
        onRequest?()
        if let result { completion(result) }
    }

    fileprivate func cancel(id: UUID) { _ = lock.withLock { pending.removeValue(forKey: id) } }
}

final class MediaImageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = MediaImageFixtureRegistry()
    private let queue = DispatchQueue(label: "MediaImageURLProtocol")
    private let id = UUID()
    private var stopped = false
    private var fixture: MediaImageFixture?

    static func install(_ fixture: MediaImageFixture) { registry.set(fixture, for: fixture.url) }
    static func remove(_ fixture: MediaImageFixture) { registry.set(nil, for: fixture.url) }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "image.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        queue.async {
            guard !self.stopped else { return }
            guard let url = self.request.url, let fixture = Self.registry.get(url) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            self.fixture = fixture
            fixture.begin(id: self.id) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped else { return }
                    let received: MediaImageFixture.Response
                    switch result {
                    case .success(let response):
                        received = response
                    case .failure(let error):
                        self.client?.urlProtocol(self, didFailWithError: error)
                        return
                    }
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                        "Content-Type": "image/png",
                        "Content-Length": String(received.data.count),
                        "Cache-Control": received.cacheControl
                    ])!
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    self.client?.urlProtocol(self, didLoad: received.data)
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
    }

    override func stopLoading() {
        queue.async {
            self.stopped = true
            self.fixture?.cancel(id: self.id)
            self.fixture = nil
        }
    }
}

private final class MediaImageFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [URL: MediaImageFixture] = [:]
    func get(_ url: URL) -> MediaImageFixture? { lock.withLock { fixtures[url] } }
    func set(_ fixture: MediaImageFixture?, for url: URL) { lock.withLock { fixtures[url] = fixture } }
}

final class MediaImageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()

    func now() -> Date { lock.withLock { value } }
    func advance(by seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
