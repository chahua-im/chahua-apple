import CoreGraphics
import Kingfisher
import SwiftUI
import XCTest
@testable import chahua_apple

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class CachedAvatarPresentationTests: XCTestCase {
    private let thumbnailSize = CGSize(width: 32, height: 32)
    func testMemoryCachedAvatarRemountStartsWithImage() async throws {
        let fixture = MediaImageFixture(
            data: try makeMediaPNG(red: 255, green: 0, blue: 255, width: 32, height: 128)
        )
        let context = try makeContext(fixture: fixture)
        let firstRecorder = AvatarPhaseRecorder()
        let firstHost = try makeHost(context: context, fixture: fixture, recorder: firstRecorder)
        defer { firstHost.close() }

        try await waitUntil("The initial Kingfisher image did not load") {
            try self.containsColor(firstHost.snapshot(), red: 255, green: 0, blue: 255)
        }
        XCTAssertEqual(fixture.requestCount, 1)
        firstHost.close()
        let remountRecorder = AvatarPhaseRecorder()
        let remountedHost = try makeHost(context: context, fixture: fixture, recorder: remountRecorder)
        defer { remountedHost.close() }
        let firstRemountedFrame = try remountedHost.snapshot()

        XCTAssertEqual(
            remountRecorder.phases.first,
            .success,
            "A memory-cached image must not expose its placeholder during a SwiftUI remount."
        )
        XCTAssertTrue(try containsColor(firstRemountedFrame, red: 255, green: 0, blue: 255))
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testAnimatedImageAdvancesAndRemountsWithoutSpinner() async throws {
        let fixture = MediaImageFixture(data: try makeMediaGIF(), contentType: "image/gif")
        let context = try makeContext(fixture: fixture)
        let firstHost = try makeAnimatedHost(context: context, fixture: fixture)
        defer { firstHost.close() }

        var sawRed = false
        var sawGreen = false
        for _ in 0 ..< 80 where !sawRed || !sawGreen {
            let snapshot = try firstHost.snapshot()
            if !sawRed {
                sawRed = try containsColor(snapshot, red: 255, green: 0, blue: 0)
            }
            if !sawGreen {
                sawGreen = try containsColor(snapshot, red: 0, green: 255, blue: 0)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(sawRed && sawGreen, "Kingfisher must present more than one GIF frame.")
        XCTAssertEqual(fixture.requestCount, 1)

        firstHost.close()
        let remountedHost = try makeAnimatedHost(context: context, fixture: fixture)
        defer { remountedHost.close() }
        let firstRemountedFrame = try remountedHost.snapshot()
        let remountShowsRed = try containsColor(firstRemountedFrame, red: 255, green: 0, blue: 0)
        let remountShowsGreen = try containsColor(firstRemountedFrame, red: 0, green: 255, blue: 0)
        XCTAssertTrue(
            remountShowsRed || remountShowsGreen,
            "A memory-cached animation must show a cached frame instead of a spinner on remount."
        )
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testSingleFrameWebPDisplaysSharpForegroundOverBackdrop() async throws {
        let fixture = MediaImageFixture(
            data: try makeMediaWebPCheckerboard(),
            contentType: "image/webp"
        )
        let context = try makeContext(fixture: fixture)
        let size = CGSize(width: 300, height: 347)
        #if os(macOS)
        let image = TimelineImageView(frame: CGRect(origin: .zero, size: size))
        image.configure(url: fixture.url, contentMode: .fit, animates: true, showsBlurredBackdrop: true,
                        thumbnailPixelSize: CGSize(width: size.width * 2, height: size.height * 2), mediaContext: context)
        image.setVisible(true)
        let host = AvatarPresentationHost(view: image, size: size)
        #else
        let image = TimelineImageView(frame: CGRect(origin: .zero, size: size))
        image.configure(url: fixture.url, contentMode: .fit, animates: true, showsBlurredBackdrop: true,
                        thumbnailPixelSize: CGSize(width: size.width * 2, height: size.height * 2), mediaContext: context)
        image.setVisible(true)
        let host = try AvatarPresentationHost(view: image, size: size)
        #endif
        host.mount()
        defer { host.close() }

        try await waitUntil("The single-frame WebP foreground stayed blurred or empty") {
            try self.hasSharpBlackAndWhitePixels(host.snapshot())
        }
        XCTAssertEqual(fixture.requestCount, 1)
    }
    func testHeldAnimationKeepsPixelsAcrossResizeVisibilityAndReuse() async throws {
        let fixture = MediaImageFixture(data: try makeMediaGIF(), contentType: "image/gif", suspended: true)
        let context = try makeContext(fixture: fixture)
        let (image, host) = try makeTimelineHost(context: context, fixture: fixture)
        defer { host.close() }
        try await waitUntil("The held image request did not start") { fixture.requestCount == 1 }
        XCTAssertTrue(hasVisibleSpinner(in: image))
        XCTAssertFalse(try containsAnimationColor(host.snapshot()))
        fixture.resume()
        try await waitUntil("The animation never displayed pixels") {
            try self.containsAnimationColor(host.snapshot())
        }
        XCTAssertFalse(hasVisibleSpinner(in: image))

        // Hold all subsequent network work: every following frame must come
        // from the view or the account's memory cache, not another download.
        fixture.suspend()
        image.configure(url: fixture.url, contentMode: .fit, animates: true, showsBlurredBackdrop: false,
                        thumbnailPixelSize: CGSize(width: 160, height: 160), mediaContext: context)
        XCTAssertTrue(try containsAnimationColor(host.snapshot()))
        XCTAssertFalse(hasVisibleSpinner(in: image))
        image.setVisible(false)
        image.setVisible(true)
        XCTAssertTrue(try containsAnimationColor(host.snapshot()))
        XCTAssertFalse(hasVisibleSpinner(in: image))

        image.clear()
        image.configure(url: fixture.url, contentMode: .fit, animates: true, showsBlurredBackdrop: false,
                        thumbnailPixelSize: CGSize(width: 240, height: 240), mediaContext: context)
        image.setVisible(true)
        XCTAssertTrue(try containsAnimationColor(host.snapshot()))
        XCTAssertFalse(hasVisibleSpinner(in: image))
        host.close()

        let (remounted, secondHost) = try makeTimelineHost(
            context: context, fixture: fixture, pixels: CGSize(width: 320, height: 320)
        )
        defer { secondHost.close() }
        XCTAssertTrue(try containsAnimationColor(secondHost.snapshot()))
        XCTAssertFalse(hasVisibleSpinner(in: remounted))
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testFailedResizePreservesDrawableFrame() async throws {
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255))
        let context = try makeContext(fixture: fixture)
        let (image, host) = try makeTimelineHost(context: context, fixture: fixture, animates: false)
        defer { host.close() }
        try await waitUntil("The first static image did not load") {
            try self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }
        await withCheckedContinuation { continuation in
            context.cache.clearCache { continuation.resume() }
        }
        fixture.fail(with: .cannotDecodeContentData)
        let terminalFailure = expectation(description: "A failed refinement must not report the drawable image as failed")
        terminalFailure.isInverted = true
        var availability: [Bool] = []
        image.onLoadFailure = { _ in terminalFailure.fulfill() }
        image.onImageAvailabilityChanged = { availability.append($0) }
        image.configure(url: fixture.url, contentMode: .fit, animates: false, showsBlurredBackdrop: false,
                        thumbnailPixelSize: CGSize(width: 256, height: 256), mediaContext: context)
        XCTAssertTrue(try containsColor(host.snapshot(), red: 255, green: 0, blue: 255))
        XCTAssertFalse(hasVisibleSpinner(in: image))
        try await waitUntil("The replacement request did not start") { fixture.requestCount == 2 }
        await fulfillment(of: [terminalFailure], timeout: 0.2)
        XCTAssertTrue(try containsColor(host.snapshot(), red: 255, green: 0, blue: 255))
        XCTAssertFalse(hasVisibleSpinner(in: image))
        XCTAssertFalse(availability.contains(false), "A failed refinement must not remove an available frame.")
    }

    func testAccountSwitchDoesNotReuseAnotherAccountsPixels() async throws {
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255))
        let firstContext = try makeContext(fixture: fixture)
        let (image, host) = try makeTimelineHost(context: firstContext, fixture: fixture)
        defer { host.close() }
        try await waitUntil("The first account image did not load") {
            try self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }
        fixture.suspend()
        fixture.replaceBody(try makeMediaPNG(red: 0, green: 255, blue: 0))
        let secondContext = try makeContext(fixture: fixture)
        image.configure(url: fixture.url, contentMode: .fit, animates: true, showsBlurredBackdrop: false,
                        thumbnailPixelSize: thumbnailSize, mediaContext: secondContext)
        try await waitUntil("The second account did not request its own image") { fixture.requestCount == 2 }
        XCTAssertTrue(hasVisibleSpinner(in: image))
        XCTAssertFalse(try containsColor(host.snapshot(), red: 255, green: 0, blue: 255))
        fixture.resume()
        try await waitUntil("The second account image did not replace the spinner") {
            try self.containsColor(host.snapshot(), red: 0, green: 255, blue: 0)
        }
        XCTAssertFalse(hasVisibleSpinner(in: image))
    }

    func testReuseIgnoresHeldOldImageFailure() async throws {
        let old = MediaImageFixture(data: try makeMediaGIF(), contentType: "image/gif", suspended: true)
        let replacement = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255), suspended: true)
        let context = try makeContext(fixture: old)
        MediaImageURLProtocol.install(replacement)
        defer { MediaImageURLProtocol.remove(replacement) }
        let (image, host) = try makeTimelineHost(context: context, fixture: old)
        defer { host.close() }
        var failures = 0
        image.onLoadFailure = { _ in failures += 1 }
        try await waitUntil("The old request did not start") { old.requestCount == 1 }
        image.configure(url: replacement.url, contentMode: .fit, animates: true, showsBlurredBackdrop: false,
                        thumbnailPixelSize: thumbnailSize, mediaContext: context)
        try await waitUntil("The reused view did not request its new image") { replacement.requestCount == 1 }
        XCTAssertTrue(hasVisibleSpinner(in: image))
        old.fail(with: .cannotDecodeContentData)
        old.resume()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(hasVisibleSpinner(in: image))
        XCTAssertEqual(failures, 0)
        replacement.resume()
        try await waitUntil("The reused view never displayed its new image") {
            try self.containsColor(host.snapshot(), red: 255, green: 0, blue: 255)
        }
        XCTAssertFalse(hasVisibleSpinner(in: image))
        XCTAssertEqual(failures, 0)
    }

    func testUndecodableImageReplacesSpinnerWithError() async throws {
        let fixture = MediaImageFixture(data: Data([0, 1, 2, 3]), contentType: "image/webp", suspended: true)
        let context = try makeContext(fixture: fixture)
        let (image, host) = try makeTimelineHost(context: context, fixture: fixture)
        defer { host.close() }
        var failure: String?
        var availability: [Bool] = []
        image.onLoadFailure = { failure = $0 }
        image.onImageAvailabilityChanged = { availability.append($0) }
        try await waitUntil("The undecodable request did not start") { fixture.requestCount == 1 }
        XCTAssertTrue(hasVisibleSpinner(in: image))
        fixture.resume()
        try await waitUntil("Undecodable media was not reported as an error") { failure != nil }
        XCTAssertFalse(hasVisibleSpinner(in: image))
        XCTAssertFalse(availability.contains(true))
        #if os(macOS)
        let visibleImages = image.subviews.compactMap { $0 as? NSImageView }.filter { !$0.isHidden && $0.image != nil }
        #else
        let visibleImages = image.subviews.compactMap { $0 as? UIImageView }.filter { !$0.isHidden && $0.image != nil }
        #endif
        XCTAssertEqual(visibleImages.count, 1, "An undecodable image must display the error symbol, not an empty surface.")
        image.configure(url: fixture.url, contentMode: .fit, animates: true, showsBlurredBackdrop: false,
                        thumbnailPixelSize: CGSize(width: 128, height: 128), mediaContext: context)
        XCTAssertFalse(hasVisibleSpinner(in: image), "Resizing failed media must not restart an unresolved spinner.")
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testAnimatedWebPMovesAndSurvivesMemoryAndDiskRemounts() async throws {
        let fixture = MediaImageFixture(data: try makeMediaWebPCheckerboard(animated: true), contentType: "image/webp")
        let context = try makeContext(fixture: fixture)
        let (image, host) = try makeTimelineHost(context: context, fixture: fixture)
        defer { host.close() }
        try await assertWebPMoves(host)
        XCTAssertFalse(hasVisibleSpinner(in: image))
        fixture.suspend()
        host.close()

        let (remounted, memoryHost) = try makeTimelineHost(
            context: context, fixture: fixture, pixels: CGSize(width: 192, height: 192)
        )
        defer { memoryHost.close() }
        let firstFrame = try checkerboardHalf(memoryHost.snapshot())
        XCTAssertNotEqual(firstFrame, 0, "A resized warm WebP must draw synchronously.")
        XCTAssertFalse(hasVisibleSpinner(in: remounted))
        memoryHost.close()
        context.clearMemoryCache()

        let (_, diskHost) = try makeTimelineHost(context: context, fixture: fixture)
        defer { diskHost.close() }
        try await assertWebPMoves(diskHost)
        XCTAssertEqual(fixture.requestCount, 1, "Disk reload must preserve animation bytes, not download or freeze a PNG.")
    }

    private func makeTimelineHost(
        context: AppMediaContext, fixture: MediaImageFixture, animates: Bool = true,
        pixels: CGSize = CGSize(width: 32, height: 32)
    ) throws -> (TimelineImageView, AvatarPresentationHost) {
        let image = TimelineImageView(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        image.configure(url: fixture.url, contentMode: .fit, animates: animates, showsBlurredBackdrop: false,
                        thumbnailPixelSize: pixels, mediaContext: context)
        image.setVisible(true)
        #if os(macOS)
        let host = AvatarPresentationHost(view: image)
        #else
        let host = try AvatarPresentationHost(view: image)
        #endif
        host.mount()
        return (image, host)
    }

    private func hasVisibleSpinner(in image: TimelineImageView) -> Bool {
        #if os(macOS)
        image.subviews.contains { ($0 as? NSProgressIndicator).map { !$0.isHidden } ?? false }
        #else
        image.subviews.contains { ($0 as? UIActivityIndicatorView).map { !$0.isHidden && $0.isAnimating } ?? false }
        #endif
    }

    private func containsAnimationColor(_ image: CGImage) throws -> Bool {
        try containsColor(image, red: 255, green: 0, blue: 0) || containsColor(image, red: 0, green: 255, blue: 0)
    }

    private func assertWebPMoves(_ host: AvatarPresentationHost) async throws {
        var sawLeft = false
        var sawRight = false
        try await waitUntil("Animated WebP never moved between its two frames") {
            let half = try self.checkerboardHalf(host.snapshot())
            sawLeft = sawLeft || half == -1
            sawRight = sawRight || half == 1
            return sawLeft && sawRight
        }
    }

    private func checkerboardHalf(_ image: CGImage) throws -> Int {
        let bytes = try pixels(image, width: image.width, height: image.height)
        var left = 0
        var right = 0
        for y in image.height / 3 ..< image.height * 2 / 3 {
            for x in 0 ..< image.width {
                let index = (y * image.width + x) * 4
                if bytes[index] < 32, bytes[index + 1] < 32, bytes[index + 2] < 32, bytes[index + 3] > 247 {
                    if x < image.width / 2 { left += 1 } else { right += 1 }
                }
            }
        }
        if left > right + 64 { return -1 }
        if right > left + 64 { return 1 }
        return 0
    }



    private func makeContext(fixture: MediaImageFixture) throws -> AppMediaContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KingfisherPresentation-\(UUID().uuidString)", isDirectory: true)
        let cache = try ImageCache(
            name: "presentation-\(UUID().uuidString)",
            cacheDirectoryURL: directory
        )
        let downloader = ImageDownloader(name: "presentation-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaImageURLProtocol.self]
        downloader.sessionConfiguration = configuration
        MediaImageURLProtocol.install(fixture)
        addTeardownBlock {
            cache.clearCache()
            MediaImageURLProtocol.remove(fixture)
            try? FileManager.default.removeItem(at: directory)
        }
        return AppMediaContext(cache: cache, downloader: downloader)
    }

    private func makeHost(
        context: AppMediaContext,
        fixture: MediaImageFixture,
        recorder: AvatarPhaseRecorder
    ) throws -> AvatarPresentationHost {
        let root = CachedImageView(url: fixture.url, thumbnailPixelSize: thumbnailSize) { phase in
            recorder.content(for: phase)
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .frame(width: 96, height: 96)
        .background(Color.white)
        .environment(\.mediaContext, context)
        let host = try AvatarPresentationHost(root: AnyView(root))
        host.mount()
        return host
    }

    private func makeAnimatedHost(
        context: AppMediaContext,
        fixture: MediaImageFixture
    ) throws -> AvatarPresentationHost {
        #if os(macOS)
        let image = TimelineImageView(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        image.configure(url: fixture.url, contentMode: .fill, animates: true, showsBlurredBackdrop: false,
                        thumbnailPixelSize: thumbnailSize, mediaContext: context)
        image.setVisible(true)
        let host = AvatarPresentationHost(view: image)
        #else
        let root = RemoteImageView(
            url: fixture.url,
            contentMode: .fill,
            animates: true,
            thumbnailPixelSize: thumbnailSize
        )
        .frame(width: 40, height: 40)
        .frame(width: 96, height: 96)
        .background(Color.white)
        .environment(\.mediaContext, context)
        let host = try AvatarPresentationHost(root: AnyView(root))
        #endif
        host.mount()
        return host
    }

    private func waitUntil(_ message: String, condition: () throws -> Bool) async throws {
        for _ in 0 ..< 150 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(
            domain: "CachedAvatarPresentationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func containsColor(_ image: CGImage, red: UInt8, green: UInt8, blue: UInt8) throws -> Bool {
        let bytes = try pixels(image, width: image.width, height: image.height)
        var matches = 0
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

    private func hasSharpBlackAndWhitePixels(_ image: CGImage) throws -> Bool {
        let bytes = try pixels(image, width: image.width, height: image.height)
        let xRange = (image.width / 8) ..< (image.width * 7 / 8)
        let yRange = (image.height / 8) ..< (image.height * 7 / 8)
        var darkPixels = 0
        var lightPixels = 0
        for y in yRange {
            for x in xRange {
                let index = (y * image.width + x) * 4
                let channels = bytes[index ... index + 2]
                if channels.allSatisfy({ $0 < 32 }) {
                    darkPixels += 1
                } else if channels.allSatisfy({ $0 > 150 }) {
                    lightPixels += 1
                }
            }
        }
        return darkPixels >= 100 && lightPixels >= 100
    }

    private func pixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
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
    var phases: [Phase] = []

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
    private let bounds: CGRect
    #if os(macOS)
    private let controller: NSViewController
    private let window: NSWindow
    #else
    private let controller: UIViewController
    private let window: UIWindow
    #endif

    init(root: AnyView, size: CGSize = CGSize(width: 96, height: 96)) throws {
        bounds = CGRect(origin: .zero, size: size)
        #if os(macOS)
        controller = NSHostingController(rootView: root)
        window = NSWindow(
            contentRect: bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        #else
        controller = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        window = UIWindow(windowScene: scene)
        window.frame = bounds
        #endif
    }

    #if os(macOS)
    init(view: NSView, size: CGSize = CGSize(width: 96, height: 96)) {
        bounds = CGRect(origin: .zero, size: size)
        controller = NSViewController()
        controller.view = view
        window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }
    #else
    init(view: UIView, size: CGSize = CGSize(width: 96, height: 96)) throws {
        bounds = CGRect(origin: .zero, size: size)
        controller = UIViewController()
        controller.view = view
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = bounds
    }
    #endif

    func mount() {
        #if os(macOS)
        window.contentViewController = controller
        window.setContentSize(bounds.size)
        window.orderFront(nil)
        controller.view.frame = bounds
        controller.view.layoutSubtreeIfNeeded()
        #else
        window.rootViewController = controller
        window.frame = bounds
        window.makeKeyAndVisible()
        controller.view.frame = bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #endif
    }

    func close() {
        #if os(macOS)
        window.contentViewController = nil
        window.close()
        #else
        window.rootViewController = nil
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
