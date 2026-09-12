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
        let root = MessageRowActionButton {} label: {
            RemoteImageView(
                url: fixture.url,
                contentMode: .fit,
                animates: true,
                showsBlurredBackdrop: true,
                thumbnailPixelSize: CGSize(width: size.width * 2, height: size.height * 2)
            )
            .modifier(BubbleMediaTileSurface(size: size, gallery: false, isVideo: false, overflowCount: 0))
        }
        .environment(\.mediaContext, context)
        let host = try AvatarPresentationHost(root: AnyView(root), size: size)
        host.mount()
        defer { host.close() }

        try await waitUntil("The single-frame WebP foreground stayed blurred or empty") {
            try self.hasSharpBlackAndWhitePixels(host.snapshot())
        }
        XCTAssertEqual(fixture.requestCount, 1)
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
    private let controller: NSHostingController<AnyView>
    private let window: NSWindow
    #else
    private let controller: UIHostingController<AnyView>
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
