import ChahuaAPI
import Combine
import CoreGraphics
import ImageIO
import Kingfisher
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import chahua_apple

@MainActor
final class MediaHostingTests: XCTestCase {
    func testStillImageSizingKeepsAllBoundsWithoutUpscaling() {
        let cases: [(Int, Int, Int, Int)] = [
            (640, 480, 640, 480),
            (6000, 4000, 2100, 1400),
            (3000, 4000, 1400, 1866),
            (10000, 1000, 8944, 894),
            (100000, 1000, 16000, 160),
        ]
        for (width, height, expectedWidth, expectedHeight) in cases {
            let size = StillImagePreparation.dimensions(width: width, height: height)
            XCTAssertEqual(size.width, expectedWidth)
            XCTAssertEqual(size.height, expectedHeight)
            XCTAssertLessThanOrEqual(min(size.width, size.height), 1400)
            XCTAssertLessThanOrEqual(max(size.width, size.height), 16000)
            XCTAssertLessThanOrEqual(size.width * size.height, 8_000_000)
            XCTAssertLessThanOrEqual(size.width, width)
            XCTAssertLessThanOrEqual(size.height, height)
        }
    }

    func testStillImageTransparencyUsesPixelsRatherThanAlphaChannelPresence() throws {
        let bitmap = try StillImagePreparation.rgbaBitmap(width: 16, height: 16)
        bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertFalse(try StillImagePreparation.hasTransparency(bitmap))
        bitmap.clear(CGRect(x: 2, y: 2, width: 1, height: 1))
        XCTAssertTrue(try StillImagePreparation.hasTransparency(bitmap))
    }

    func testStillImagePreparationProducesDecodableWebP() throws {
        let data = try makeMediaPNG(red: 200, green: 50, blue: 30, width: 1024, height: 768)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = try XCTUnwrap(
            StillImagePreparation.prepare(
                source: source, originalByteCount: Int64(data.count), directory: directory))
        XCTAssertEqual(output.mimeType, "image/webp")
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(output.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(encoded) as String?, UTType.webP.identifier)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        XCTAssertEqual(decoded.width, 1024)
        XCTAssertEqual(decoded.height, 768)
    }

    func testStillImagePreparationRetainsAnimatedOriginal() throws {
        let data = try makeMediaGIF()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertNil(
            try StillImagePreparation.prepare(
                source: source, originalByteCount: Int64(data.count),
                directory: FileManager.default.temporaryDirectory))
    }

    func testClearingMediaCacheRefreshesDiskUsageWithoutTouchingOtherCaches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let first = try ImageCache(name: UUID().uuidString, cacheDirectoryURL: directory)
        let second = try ImageCache(name: UUID().uuidString, cacheDirectoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(repeating: 0x41, count: 4096)
        try await first.storeToDisk(data, forKey: "image")
        try await second.storeToDisk(data, forKey: "other-account")
        let model = MediaCacheSettingsModel(
            mediaContext: AppMediaContext(cache: first, downloader: .default))
        await model.refresh()
        XCTAssertGreaterThan(model.diskStorageSize, 0)

        await model.clear()
        XCTAssertEqual(model.state, .cleared)
        XCTAssertEqual(model.diskStorageSize, 0)
        let otherAccountBytes = try await second.diskStorageSize
        XCTAssertGreaterThan(otherAccountBytes, 0)
    }

    func testLimitedImageLoadRequiresTapAndOfflinePlaybackUsesOnlyAccountCache() async throws {
        let data = try makeMediaPNG(red: 255, green: 0, blue: 0)
        let fixture = MediaImageFixture(data: data)
        MediaImageURLProtocol.install(fixture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer {
            MediaImageURLProtocol.remove(fixture)
            try? FileManager.default.removeItem(at: directory)
        }
        let downloader = ImageDownloader(name: UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaImageURLProtocol.self]
        downloader.sessionConfiguration = configuration
        let cache = try ImageCache(name: "first", cacheDirectoryURL: directory)
        let connectivity = ConnectivityMonitor(monitorNetwork: false)
        connectivity.update(.init(status: .satisfied, isExpensive: true))
        let context = AppMediaContext(cache: cache, downloader: downloader, connectivity: connectivity)
        let item = MessageImageItem(
            id: "attachment", url: fixture.url, contentType: "image/png",
            fileName: "attachment.png", width: 16, height: 16)
        let loader = ImageDetailImageLoader()
        let unavailable = expectation(description: "Automatic full image fetch was suppressed")
        let failure = loader.$failure.sink {
            if $0 == .notDownloaded { unavailable.fulfill() }
        }
        loader.load(item, mediaContext: context)
        await fulfillment(of: [unavailable], timeout: 2)
        failure.cancel()
        XCTAssertFalse(loader.isLoading)
        XCTAssertEqual(fixture.requestCount, 0)

        let opened = expectation(description: "An explicit open fetched the full image")
        let loaded = loader.$image.sink { if $0 != nil { opened.fulfill() } }
        loader.load(item, mediaContext: context, userInitiated: true)
        await fulfillment(of: [opened], timeout: 2)
        loaded.cancel()
        XCTAssertEqual(fixture.requestCount, 1)

        try await cache.storeToDisk(data, forKey: fixture.url.absoluteString)
        XCTAssertTrue(cache.diskStorage.isCached(
            forKey: fixture.url.absoluteString,
            referenceDate: Date.now.addingTimeInterval(365 * 24 * 60 * 60)))
        cache.clearMemoryCache()
        connectivity.update(.init(status: .unsatisfied))
        let cachedLoader = ImageDetailImageLoader()
        let cached = expectation(description: "The downloaded image was opened from disk")
        let cachedImage = cachedLoader.$image.sink { if $0 != nil { cached.fulfill() } }
        cachedLoader.load(item, mediaContext: context, userInitiated: true)
        await fulfillment(of: [cached], timeout: 2)
        cachedImage.cancel()

        let otherCache = try ImageCache(name: "second", cacheDirectoryURL: directory)
        let otherContext = AppMediaContext(
            cache: otherCache, downloader: downloader, connectivity: connectivity)
        let otherLoader = ImageDetailImageLoader()
        let isolated = expectation(description: "Another account did not reuse the image")
        let otherFailure = otherLoader.$failure.sink {
            if $0 == .notDownloaded { isolated.fulfill() }
        }
        otherLoader.load(item, mediaContext: otherContext, userInitiated: true)
        await fulfillment(of: [isolated], timeout: 2)
        otherFailure.cancel()
        XCTAssertFalse(otherLoader.isLoading)
        XCTAssertNil(otherLoader.image)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testVideoCacheOnlyMissDoesNotContactTheServer() async throws {
        let fixture = MediaImageFixture(data: Data())
        MediaImageURLProtocol.install(fixture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer {
            MediaImageURLProtocol.remove(fixture)
            try? FileManager.default.removeItem(at: directory)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaImageURLProtocol.self]
        let cache = VideoFileCache(directory: directory, configuration: configuration)
        do {
            _ = try await cache.file(for: fixture.url, allowsNetwork: false) { _ in
                XCTFail("A cache-only lookup must not start progress")
            }
            XCTFail("The empty cache must not provide a lease")
        } catch VideoFileCache.CacheMiss.notDownloaded {
            XCTAssertEqual(fixture.requestCount, 0)
        }
    }

    func testPreparingGeometryDoesNotAcquireRemoteAvatars() async throws {
        let requested = expectation(description: "Geometry preparation must not request an avatar")
        requested.isInverted = true
        let fixture = MediaImageFixture(
            data: try makeMediaPNG(red: 255, green: 0, blue: 255),
            onRequest: { requested.fulfill() })
        MediaImageURLProtocol.install(fixture)
        defer { MediaImageURLProtocol.remove(fixture) }
        let message = try TimelineTestFixtures.message(
            id: 1, senderID: 2, at: 0,
            fields: [
                "sender": [
                    "uid": 2, "gender": 0, "name": "Remote sender",
                    "avatarUrl": fixture.url.absoluteString,
                ]
            ])
        let row = TimelineRow.message(
            .init(
                entry: .remote(message), isOutgoing: false, groupPosition: .single,
                showsSenderName: true))
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 400)
        let presentation = TimelineRowPresentation.make(
            row: row, currentUserID: 1, isThreadTimeline: false, environment: environment)
        let cache = TimelineLayoutCache()
        let layout = cache.layout(for: presentation, environment: environment)
        XCTAssertNotNil(layout.frames[.avatar])
        await fulfillment(of: [requested], timeout: 0.2)
        XCTAssertEqual(fixture.requestCount, 0)
    }

    #if os(iOS)
        func testStickerEnteringViewportLoadsWithoutReconfiguration() async throws {
            let requested = expectation(description: "Entering the viewport acquires the sticker")
            let data = try makeMediaPNG(red: 255, green: 0, blue: 0)
            let fixture = MediaImageFixture(
                data: data,
                suspended: true, onRequest: { requested.fulfill() })
            MediaImageURLProtocol.install(fixture)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            let cache = try ImageCache(name: UUID().uuidString, cacheDirectoryURL: directory)
            let downloader = ImageDownloader(name: UUID().uuidString)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MediaImageURLProtocol.self]
            downloader.sessionConfiguration = configuration
            let context = AppMediaContext(cache: cache, downloader: downloader)
            defer {
                MediaImageURLProtocol.remove(fixture)
                cache.clearCache()
                try? FileManager.default.removeItem(at: directory)
            }

            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
            scroll.contentSize = CGSize(width: 320, height: 1800)
            controller.view.addSubview(scroll)
            let surface = StickerMediaSurfaceView(
                frame: CGRect(x: 20, y: 1200, width: 72, height: 72))
            scroll.addSubview(surface)
            surface.configure(
                media: .init(
                    id: "scrolling-sticker", url: fixture.url.absoluteString,
                    contentType: "image/png", size: Int64(data.count), width: 16, height: 16),
                emoji: "", displayScale: 1, mediaContext: context)
            surface.setVisible(true)
            surface.layoutIfNeeded()
            XCTAssertEqual(fixture.requestCount, 0)

            // No configure/setVisible/layout call after scrolling: ancestor movement
            // must wake the cell which appeared while still outside the viewport.
            scroll.setContentOffset(CGPoint(x: 0, y: 1160), animated: false)
            await fulfillment(of: [requested], timeout: 2)
            let renderer = try XCTUnwrap(
                surface.subviews.compactMap { $0 as? TimelineImageView }.first)
            let spinner = try XCTUnwrap(
                renderer.subviews.compactMap { $0 as? UIActivityIndicatorView }.first)
            XCTAssertTrue(
                spinner.isAnimating,
                "A visible pending sticker must not be blank without loading chrome")
            let available = expectation(
                description: "The visible sticker draws its downloaded pixels")
            renderer.onImageAvailabilityChanged = { if $0 { available.fulfill() } }
            fixture.resume()
            await fulfillment(of: [available], timeout: 2)
            renderer.layoutIfNeeded()
            renderer.layer.displayIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: renderer.bounds).image {
                renderer.layer.render(in: $0.cgContext)
            }
            let pixels = try XCTUnwrap(image.cgImage)
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { buffer in
                let bitmap = try XCTUnwrap(
                    CGContext(
                        data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.draw(pixels, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertGreaterThan(rgba[0], 220)
            XCTAssertLessThan(rgba[1], 30)
            XCTAssertGreaterThan(rgba[3], 220)
            XCTAssertFalse(spinner.isAnimating)
        }
    #endif
}
