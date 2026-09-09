import CoreGraphics
import Foundation
import Nuke
import SwiftUI
import XCTest
@testable import ChahuaMediaCache
@testable import chahua_apple

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class CachedAvatarPresentationTests: XCTestCase {
    private let avatars = CacheTag(rawValue: "avatars")
    private let chatMedia = CacheTag(rawValue: "chatMedia")
    private let thumbnailSize = CGSize(width: 32, height: 32)

    func testExpiredMemoryAvatarFirstSynchronousViewPhaseIsImage() async throws {
        let clock = MediaImageClock()
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255))
        let context = makeContext(fixture: fixture, clock: { clock.now() })
        let resources = try await context.resources(for: context.activationID)
        _ = try await resources.images.image(for: request(fixture), thumbnailPixelSize: thumbnailSize)
        clock.advance(by: 3601)
        fixture.suspend()
        defer { fixture.resume() }
        let recorder = AvatarPhaseRecorder()

        // No suspension between constructing the fresh view and checking its first phase.
        // The recorder also preserves that first phase if native drawing pumps a run loop.
        let host = try makeHost(context: context, fixture: fixture, recorder: recorder)
        defer { host.close() }
        let firstFrame = try host.snapshot()
        #if os(macOS)
        let attachment = XCTAttachment(image: NSImage(cgImage: firstFrame, size: NSSize(width: 96, height: 96)))
        #else
        let attachment = XCTAttachment(image: UIImage(cgImage: firstFrame))
        #endif
        attachment.name = "Warmed avatar first synchronous frame"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(recorder.phases.first, .success,
                       "A warmed avatar must not offer its placeholder to the content closure first.")
        XCTAssertTrue(try containsColor(firstFrame, red: 255, green: 0, blue: 255))
        try await waitUntil("The immediate expired image must still start freshness acquisition") {
            fixture.requestCount == 2
        }
        XCTAssertTrue(try containsColor(host.snapshot(), red: 255, green: 0, blue: 255))
    }

    func testImmediateImageRequiresMatchingThumbnailAndDurableTagsAndOpenLoader() async throws {
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255, width: 32, height: 128))
        let context = makeContext(fixture: fixture)
        let resources = try await context.resources(for: context.activationID)
        let avatarRequest = request(fixture)
        _ = try await resources.images.image(for: avatarRequest, thumbnailPixelSize: thumbnailSize)

        let immediate = try XCTUnwrap(context.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))
        XCTAssertEqual(immediate.cacheType, .memory)
        XCTAssertEqual(try pixel(immediate), [255, 0, 255, 255])
        XCTAssertNil(context.cachedImage(for: avatarRequest, thumbnailPixelSize: CGSize(width: 16, height: 16)))
        XCTAssertNil(context.cachedImage(for: avatarRequest), "A thumbnail is not the full-resolution image cache entry.")

        let bothTags = MediaRequest(request: URLRequest(url: fixture.url), tags: [avatars, chatMedia])
        XCTAssertNil(context.cachedImage(for: bothTags, thumbnailPixelSize: thumbnailSize))
        let beforeRegistration = try await resources.cache.usage()
        XCTAssertNil(beforeRegistration.byTag[chatMedia], "Synchronous presentation must not register a new tag.")
        XCTAssertEqual(fixture.requestCount, 1)

        let registered = try await resources.images.image(for: bothTags, thumbnailPixelSize: thumbnailSize)
        XCTAssertEqual(registered.cacheType, .memory)
        let taggedImage = try XCTUnwrap(context.cachedImage(for: bothTags, thumbnailPixelSize: thumbnailSize))
        XCTAssertEqual(try pixel(taggedImage), [255, 0, 255, 255])
        let afterRegistration = try await resources.cache.usage()
        XCTAssertEqual(afterRegistration.byTag[chatMedia]?.completeItemCount, 1)
        XCTAssertEqual(fixture.requestCount, 1)

        resources.images.close()
        XCTAssertNil(resources.images.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))
        XCTAssertNil(context.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))
    }

    func testFreshViewCannotReplayDecodedAvatarAfterCategoryRemoval() async throws {
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255))
        let context = makeContext(fixture: fixture)
        let resources = try await context.resources(for: context.activationID)
        let avatarRequest = request(fixture)
        _ = try await resources.images.image(for: avatarRequest, thumbnailPixelSize: thumbnailSize)
        XCTAssertNotNil(context.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))

        _ = try await resources.cache.remove(tag: avatars)
        fixture.replaceBody(try makeMediaPNG(red: 0, green: 255, blue: 0))
        XCTAssertNil(resources.images.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))
        XCTAssertNil(context.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))
        let recorder = AvatarPhaseRecorder()
        let host = try makeHost(context: context, fixture: fixture, recorder: recorder)
        defer { host.close() }
        _ = try host.snapshot()
        XCTAssertEqual(recorder.phases.first, .empty,
                       "A fresh view must not revive Nuke's decoded image for a revoked generation.")

        try await waitUntil("The cleared avatar was not replaced with the new generation's pixels") {
            try self.containsColor(host.snapshot(), red: 0, green: 255, blue: 0)
        }
        let replacement = try XCTUnwrap(context.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))
        XCTAssertEqual(try pixel(replacement), [0, 255, 0, 255])
        XCTAssertEqual(fixture.requestCount, 2)
    }

    func testNewActivationCannotKeepPreviouslyDisplayedAccountAvatar() async throws {
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255))
        let context = makeContext(fixture: fixture)
        let oldResources = try await context.resources(for: context.activationID)
        let avatarRequest = request(fixture)
        _ = try await oldResources.images.image(for: avatarRequest, thumbnailPixelSize: thumbnailSize)
        XCTAssertNotNil(context.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))
        let recorder = AvatarPhaseRecorder()
        let host = try makeHost(context: context, fixture: fixture, recorder: recorder)
        defer { host.close() }
        try await waitUntil("The first account's avatar did not appear") {
            try self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }

        fixture.replaceBody(try makeMediaPNG(red: 0, green: 0, blue: 255))
        fixture.suspend()
        defer { fixture.resume() }
        let oldActivation = context.activationID
        context.activate(uid: 2)
        XCTAssertNotEqual(context.activationID, oldActivation)
        // These checks run before the ordered shutdown/new-cache initialization can finish.
        XCTAssertNil(context.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))
        XCTAssertNil(oldResources.images.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))
        try await waitUntil("The held old-account pixels survived an activation change") {
            try !self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }
        fixture.resume()

        try await waitUntil("The new account's avatar did not appear") {
            try self.containsColor(host.snapshot(), red: 0, green: 0, blue: 255)
        }
        let replacement = try XCTUnwrap(context.cachedImage(for: avatarRequest, thumbnailPixelSize: thumbnailSize))
        XCTAssertEqual(try pixel(replacement), [0, 0, 255, 255])
        XCTAssertEqual(fixture.requestCount, 2)
    }

    func testReappearingAvatarDropsCorruptGenerationWhileRepairWaits() async throws {
        let gate = AvatarResponseGate()
        defer { gate.open() }
        let fixture = MediaImageFixture(
            data: try makeMediaPNG(red: 255, green: 0, blue: 255),
            onRequest: { gate.receivedRequest() }
        )
        let context = makeContext(fixture: fixture)
        let resources = try await context.resources(for: context.activationID)
        let recorder = AvatarPhaseRecorder()
        let host = try makeHost(context: context, fixture: fixture, recorder: recorder)
        defer { host.close() }

        // Start cold so observing success proves the view's own asynchronous load finished,
        // rather than merely observing the synchronous warmed-image presentation.
        try await waitUntil("The initial avatar load did not finish") {
            guard recorder.phases.contains(.success) else { return false }
            return try self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }
        host.detach()
        try await waitUntil("The native host did not disappear") { recorder.disappearances == 1 }

        let file = try await resources.cache.file(for: request(fixture))
        let payloadURL = file.url
        await file.release()
        // Model external OS eviction without the explicit cache-clear fence: synchronous
        // metadata lookup intentionally cannot discover a missing file. The next task must.
        try FileManager.default.removeItem(at: payloadURL)
        fixture.replaceBody(try makeMediaPNG(red: 0, green: 0, blue: 255))
        XCTAssertNotNil(context.cachedImage(for: request(fixture), thumbnailPixelSize: thumbnailSize))
        host.mount()

        try await waitUntil("Reappearance did not acquire the file again") {
            _ = try host.snapshot()
            return gate.isWaiting
        }
        XCTAssertEqual(recorder.appearances, 2)
        XCTAssertEqual(fixture.requestCount, 2, "A memory image must not bypass the asynchronous file acquisition.")
        XCTAssertNil(context.cachedImage(for: request(fixture), thumbnailPixelSize: thumbnailSize),
                     "Acquisition must revoke the missing generation before fetching its replacement.")
        try await waitUntil("A repaired missing generation must revoke previously displayed pixels") {
            try !self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }

        gate.open()
        try await waitUntil("The replay did not finish with the replacement avatar") {
            try self.containsColor(host.snapshot(), red: 0, green: 0, blue: 255)
        }
        XCTAssertFalse(gate.timedOut, "The response must be released by the test, not its safety timeout.")
        XCTAssertEqual(fixture.requestCount, 2)
    }

    func testDiskWarmExpiredAvatarsShowOldThenNewPixelsDuringSharedRefresh() async throws {
        let clock = MediaImageClock()
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255))
        let context = makeContext(fixture: fixture, clock: { clock.now() })
        let resources = try await context.resources(for: context.activationID)
        let file = try await resources.cache.file(for: request(fixture))
        await file.release()
        clock.advance(by: 3601)
        XCTAssertNil(context.cachedImage(for: request(fixture), thumbnailPixelSize: thumbnailSize),
                     "This scenario must start decoded-memory cold, not just expired.")
        fixture.replaceBody(try makeMediaPNG(red: 0, green: 255, blue: 0))
        fixture.suspend()
        defer { fixture.resume() }
        let first = try makeHost(context: context, fixture: fixture, recorder: AvatarPhaseRecorder())
        defer { first.close() }
        let second = try makeHost(context: context, fixture: fixture, recorder: AvatarPhaseRecorder())
        defer { second.close() }

        try await waitUntil("Both disk-warm avatars must decode while HTTP is suspended") {
            try self.containsColor(first.snapshot(), red: 255, green: 0, blue: 255)
                && self.containsColor(second.snapshot(), red: 255, green: 0, blue: 255)
                && fixture.requestCount == 2
        }
        XCTAssertFalse(try containsColor(first.snapshot(), red: 0, green: 255, blue: 0))
        fixture.resume()
        try await waitUntil("Both hosted avatars must display the refreshed generation") {
            try self.containsColor(first.snapshot(), red: 0, green: 255, blue: 0)
                && self.containsColor(second.snapshot(), red: 0, green: 255, blue: 0)
        }
        XCTAssertFalse(try containsColor(first.snapshot(), red: 255, green: 0, blue: 255))
        XCTAssertEqual(fixture.requestCount, 2, "Simultaneous views must share one package HTTP producer.")
    }

    func testFailedRefreshKeepsHostedStalePixelsUntilExplicitRemoval() async throws {
        let clock = MediaImageClock()
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255))
        let context = makeContext(fixture: fixture, clock: { clock.now() })
        let resources = try await context.resources(for: context.activationID)
        _ = try await resources.images.image(for: request(fixture), thumbnailPixelSize: thumbnailSize)
        clock.advance(by: 3601)
        fixture.suspend()
        fixture.fail(with: .notConnectedToInternet)
        defer { fixture.resume() }
        let recorder = AvatarPhaseRecorder()
        let host = try makeHost(context: context, fixture: fixture, recorder: recorder)
        defer { host.close() }
        try await waitUntil("The stale image must remain visible while offline refresh waits") {
            try self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
                && fixture.requestCount == 2
        }
        fixture.resume()
        // Poll rendered frames after delivering the failure, not just the optimistic first frame.
        for _ in 0 ..< 10 {
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(try containsColor(host.snapshot(), red: 255, green: 0, blue: 255))
        }
        XCTAssertFalse(recorder.phases.contains(.failure), "A failed refresh must not replace valid stale pixels.")
        XCTAssertEqual(fixture.requestCount, 2)
        _ = try await resources.cache.remove(tag: avatars)
        try await waitUntil("Explicit removal must revoke a settled failed-refresh image") {
            try !self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }
    }

    func testRemovalDuringSuspendedRefreshRevokesAlreadyDisplayedStalePixels() async throws {
        let clock = MediaImageClock()
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255))
        let context = makeContext(fixture: fixture, clock: { clock.now() })
        let resources = try await context.resources(for: context.activationID)
        _ = try await resources.images.image(for: request(fixture), thumbnailPixelSize: thumbnailSize)
        clock.advance(by: 3601)
        fixture.suspend()
        defer { fixture.resume() }
        let host = try makeHost(context: context, fixture: fixture, recorder: AvatarPhaseRecorder())
        defer { host.close() }
        try await waitUntil("The stale image must be displayed before revocation") {
            try self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
                && fixture.requestCount == 2
        }
        _ = try await resources.cache.remove(tag: avatars)
        try await waitUntil("Removing a tag must fence an in-flight stale presentation") {
            try !self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }
        fixture.resume()
        for _ in 0 ..< 10 {
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertFalse(try containsColor(host.snapshot(), red: 255, green: 0, blue: 255))
        }
    }

    func testExplicitRemovalRevokesDisplayedNoStorePixelsAfterLeaseCleanup() async throws {
        let fixture = MediaImageFixture(
            data: try makeMediaPNG(red: 255, green: 0, blue: 255), cacheControl: "no-store"
        )
        let context = makeContext(fixture: fixture)
        let resources = try await context.resources(for: context.activationID)
        let host = try makeHost(context: context, fixture: fixture, recorder: AvatarPhaseRecorder())
        defer { host.close() }
        try await waitUntil("A newly fetched no-store image must still be displayable") {
            try self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }
        let usage = try await resources.cache.usage()
        XCTAssertEqual(usage.total.itemCount, 0, "Displaying pixels must not pin no-store disk leases.")
        _ = try await resources.cache.remove(tag: chatMedia)
        XCTAssertTrue(try containsColor(host.snapshot(), red: 255, green: 0, blue: 255),
                      "An unrelated category removal must not clear this image.")
        _ = try await resources.cache.remove(tag: avatars)
        try await waitUntil("Explicit removal must revoke pixels even after automatic no-store cleanup") {
            try !self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }
    }

    private func makeContext(
        fixture: MediaImageFixture, clock: @escaping @Sendable () -> Date = { Date() }
    ) -> AppMediaContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CachedAvatarPresentation-\(UUID().uuidString)", isDirectory: true)
        MediaImageURLProtocol.install(fixture)
        let context = AppMediaContext(rootDirectory: directory, namespace: "avatar-presentation-tests") { configuration in
            try await MediaCache(configuration: configuration,
                                 protocolClasses: [MediaImageURLProtocol.self], clock: clock)
        }
        addTeardownBlock { @MainActor in
            context.activate(uid: nil)
            _ = try? await context.resources(for: context.activationID)
            MediaImageURLProtocol.remove(fixture)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        context.activate(uid: 1)
        return context
    }

    private func request(_ fixture: MediaImageFixture) -> MediaRequest {
        MediaRequest(request: URLRequest(url: fixture.url), tags: [avatars])
    }

    private func makeHost(
        context: AppMediaContext, fixture: MediaImageFixture, recorder: AvatarPhaseRecorder
    ) throws -> AvatarPresentationHost {
        let root = CachedImageView(url: fixture.url, tag: avatars, thumbnailPixelSize: thumbnailSize) { phase in
            recorder.content(for: phase)
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .onAppear { recorder.appearances += 1 }
        .onDisappear { recorder.disappearances += 1 }
        .frame(width: 96, height: 96)
        .background(Color.white)
        .environment(\.mediaContext, context)
        let host = try AvatarPresentationHost(root: AnyView(root))
        host.mount()
        return host
    }

    private func waitUntil(_ message: String, condition: () throws -> Bool) async throws {
        for _ in 0 ..< 150 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "CachedAvatarPresentationTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func pixel(_ response: ImageResponse) throws -> [UInt8] {
        #if os(macOS)
        let image = try XCTUnwrap(response.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #else
        let image = try XCTUnwrap(response.image.cgImage)
        #endif
        return try pixels(image, width: 1, height: 1)
    }

    private func containsColor(_ image: CGImage, red: UInt8, green: UInt8, blue: UInt8) throws -> Bool {
        let bytes = try pixels(image, width: image.width, height: image.height)
        var matches = 0
        // Native snapshots are display-color-managed. Distinguish the primary-color
        // fixtures here; decoded-image assertions above check exact sRGB bytes.
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if abs(Int(bytes[index]) - Int(red)) < 64,
               abs(Int(bytes[index + 1]) - Int(green)) < 64,
               abs(Int(bytes[index + 2]) - Int(blue)) < 64,
               bytes[index + 3] > 247 {
                matches += 1
                if matches >= 64 { return true }
            }
        }
        return false
    }

    private func pixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(
                data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}

@MainActor
private final class AvatarPhaseRecorder {
    enum Phase: Equatable { case empty, success, failure }
    // This is deliberately not observable or SwiftUI state: recording body evaluation
    // cannot cause another evaluation or replace the first phase with an eventual one.
    var phases: [Phase] = []
    var appearances = 0
    var disappearances = 0

    func content(for phase: RemoteImagePhase) -> AnyView {
        switch phase {
        case .empty:
            phases.append(.empty)
            return AnyView(Color.black)
        case .success(let image):
            phases.append(.success)
            return AnyView(image.resizable().scaledToFill())
        case .failure:
            phases.append(.failure)
            return AnyView(Color.yellow)
        }
    }
}

@MainActor
private final class AvatarPresentationHost {
    private static let bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
    #if os(macOS)
    private let controller: NSHostingController<AnyView>
    private let window: NSWindow
    #else
    private let controller: UIHostingController<AnyView>
    private let window: UIWindow
    #endif

    init(root: AnyView) throws {
        #if os(macOS)
        controller = NSHostingController(rootView: root)
        window = NSWindow(contentRect: Self.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #else
        controller = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = Self.bounds
        #endif
    }

    func mount() {
        #if os(macOS)
        window.contentViewController = controller
        window.setContentSize(Self.bounds.size)
        window.orderFront(nil)
        controller.view.frame = Self.bounds
        controller.view.layoutSubtreeIfNeeded()
        #else
        window.rootViewController = controller
        window.frame = Self.bounds
        window.makeKeyAndVisible()
        controller.view.frame = Self.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #endif
    }

    func detach() {
        #if os(macOS)
        window.contentViewController = nil
        #else
        window.rootViewController = nil
        #endif
    }

    func close() {
        detach()
        #if os(macOS)
        window.close()
        #else
        window.isHidden = true
        #endif
    }

    func snapshot() throws -> CGImage {
        #if os(macOS)
        let view = controller.view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.cgImage)
        #else
        let view = controller.view!
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(image.cgImage)
        #endif
    }
}

private final class AvatarResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var requests = 0
    private var waiting = false
    private var timeout = false

    var isWaiting: Bool { lock.withLock { waiting } }
    var timedOut: Bool { lock.withLock { timeout } }

    func receivedRequest() {
        let shouldWait = lock.withLock {
            requests += 1
            return requests == 2
        }
        guard shouldWait else { return }
        lock.withLock { waiting = true }
        // MediaImageURLProtocol invokes this on its private serial queue, never on
        // MainActor or a Swift cooperative executor. Bound failed-test cleanup too.
        let result = semaphore.wait(timeout: .now() + 10)
        lock.withLock {
            waiting = false
            timeout = result == .timedOut
        }
    }

    func open() { semaphore.signal() }
}
