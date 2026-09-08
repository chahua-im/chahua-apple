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

    private func makeContext(fixture: MediaImageFixture) -> AppMediaContext {
        let directory = temporaryDirectory()
        MediaImageURLProtocol.install(fixture)
        let context = AppMediaContext(rootDirectory: directory, namespace: "injected") { configuration in
            try await MediaCache(configuration: configuration, protocolClasses: [MediaImageURLProtocol.self], clock: { Date() })
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
    let url = URL(string: "https://image.invalid/\(UUID().uuidString).png")!
    private let lock = NSLock()
    private var body: Data
    private var suspended: Bool
    private var count = 0
    private var pending: [UUID: @Sendable (Data) -> Void] = [:]
    private let onRequest: (@Sendable () -> Void)?

    init(data: Data, suspended: Bool = false, onRequest: (@Sendable () -> Void)? = nil) {
        body = data
        self.suspended = suspended
        self.onRequest = onRequest
    }

    var requestCount: Int { lock.withLock { count } }

    func replaceBody(_ data: Data) { lock.withLock { body = data } }

    func resume() {
        let (callbacks, data) = lock.withLock {
            suspended = false
            let callbacks = Array(pending.values)
            pending.removeAll()
            return (callbacks, body)
        }
        for callback in callbacks { callback(data) }
    }

    fileprivate func begin(id: UUID, completion: @escaping @Sendable (Data) -> Void) {
        let data: Data? = lock.withLock {
            count += 1
            if suspended {
                pending[id] = completion
                return nil
            }
            return body
        }
        onRequest?()
        if let data { completion(data) }
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
            fixture.begin(id: self.id) { [weak self] data in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped else { return }
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                        "Content-Type": "image/png",
                        "Content-Length": String(data.count),
                        "Cache-Control": "max-age=3600"
                    ])!
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    self.client?.urlProtocol(self, didLoad: data)
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
