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
    func testNetworkLimitsApplyToVideoButNotImages() {
        for snapshot in [
            ConnectivitySnapshot(status: .satisfied, isExpensive: true),
            ConnectivitySnapshot(status: .satisfied, isConstrained: true),
        ] {
            let policy = MediaLoadPolicy(snapshot)
            XCTAssertTrue(policy.allowsNetwork())
            XCTAssertFalse(policy.allowsNetwork(isVideo: true))
            XCTAssertTrue(policy.allowsNetwork(isVideo: true, userInitiated: true))
        }
        let offline = MediaLoadPolicy(.init(status: .unsatisfied))
        XCTAssertTrue(offline.allowsNetwork())
        XCTAssertFalse(offline.allowsNetwork(isVideo: true, userInitiated: true))
        XCTAssertFalse(MediaLoadPolicy.cacheOnly.allowsNetwork(userInitiated: true))
    }

    func testStickerArtworkFitsTimelineAndPickerWithoutUpscaling() throws {
        let cases: [(Int32, Int32, CGSize, Bool, CGSize)] = [
            (32, 32, CGSize(width: 200, height: 200), false, CGSize(width: 32, height: 32)),
            (640, 640, CGSize(width: 200, height: 200), false, CGSize(width: 200, height: 200)),
            (64, 32, CGSize(width: 200, height: 100), false, CGSize(width: 64, height: 32)),
            (640, 320, CGSize(width: 200, height: 100), false, CGSize(width: 200, height: 100)),
            (320, 640, CGSize(width: 100, height: 200), false, CGSize(width: 100, height: 200)),
            (32, 16, CGSize(width: 72, height: 72), true, CGSize(width: 32, height: 16)),
            (640, 320, CGSize(width: 72, height: 72), true, CGSize(width: 54.72, height: 27.36)),
        ]
        for (width, height, bounds, inset, expected) in cases {
            let surface = StickerMediaSurfaceView(frame: CGRect(origin: .zero, size: bounds))
            surface.configure(
                media: .init(
                    id: "sticker", url: "https://example.test/sticker.png",
                    contentType: "image/png", size: 0, width: width, height: height),
                emoji: "", displayScale: 2, mediaContext: nil, insetsArtwork: inset)
            defer { surface.clear() }
            let image = try XCTUnwrap(
                surface.subviews.compactMap { $0 as? TimelineImageView }.first)
            XCTAssertEqual(image.frame.width, expected.width, accuracy: 0.01)
            XCTAssertEqual(image.frame.height, expected.height, accuracy: 0.01)
            XCTAssertEqual(image.frame.midX, surface.bounds.midX, accuracy: 0.01)
            XCTAssertEqual(image.frame.midY, surface.bounds.midY, accuracy: 0.01)
        }
    }

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

    func testCellularImageLoadsAutomaticallyAndOfflinePlaybackUsesOnlyAccountCache() async throws {
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
        let context = AppMediaContext(
            cache: cache, downloader: downloader, connectivity: connectivity)
        let item = MessageImageItem(
            id: "attachment", url: fixture.url, contentType: "image/png",
            fileName: "attachment.png", width: 16, height: 16)
        let loader = ImageDetailImageLoader()
        let opened = expectation(
            description: "A cellular connection fetched the full image automatically")
        let loaded = loader.$image.sink { if $0 != nil { opened.fulfill() } }
        loader.load(item, mediaContext: context)
        await fulfillment(of: [opened], timeout: 2)
        loaded.cancel()
        XCTAssertEqual(fixture.requestCount, 1)

        try await cache.storeToDisk(data, forKey: fixture.url.absoluteString)
        XCTAssertTrue(
            cache.diskStorage.isCached(
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
        otherContext.setNetworkAuthorized(false)
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

    func testStickerEnteringViewportLoadsWithoutReconfiguration() async throws {
        let requested = expectation(description: "Entering the viewport acquires the sticker")
        let data = try makeMediaPNG(red: 255, green: 0, blue: 0)
        let fixture = MediaImageFixture(
            data: data, suspended: true, onRequest: { requested.fulfill() })
        MediaImageURLProtocol.install(fixture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let cache = try ImageCache(name: UUID().uuidString, cacheDirectoryURL: directory)
        let downloader = ImageDownloader(name: UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaImageURLProtocol.self]
        downloader.sessionConfiguration = configuration
        let connectivity = ConnectivityMonitor(monitorNetwork: false)
        connectivity.update(.init(status: .satisfied, isExpensive: true))
        let context = AppMediaContext(
            cache: cache, downloader: downloader, connectivity: connectivity)
        defer {
            MediaImageURLProtocol.remove(fixture)
            cache.clearCache()
            try? FileManager.default.removeItem(at: directory)
        }

        let message = try TimelineTestFixtures.message(
            id: 1, senderID: 2, at: 0,
            fields: [
                "messageType": "sticker",
                "sticker": [
                    "id": "scrolling-sticker", "emoji": "🙂",
                    "createdAt": "2026-09-01T00:00:00Z",
                    "media": [
                        "id": "sticker-media", "url": fixture.url.absoluteString,
                        "contentType": "image/png", "size": data.count,
                        "width": 16, "height": 16,
                    ],
                ],
            ])
        let row = TimelineRow.message(
            .init(
                entry: .remote(message), isOutgoing: false, groupPosition: .single,
                showsSenderName: false))
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 320)
        let presentation = TimelineRowPresentation.make(
            row: row, currentUserID: 1, isThreadTimeline: false, environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        let frame = try XCTUnwrap(layout.frames[.media])
        let media = TimelineMediaView(
            frame: CGRect(origin: CGPoint(x: 20, y: 1200), size: frame.size))
        media.bind(
            .init(
                presentation: presentation, layout: layout, context: .init(currentUserID: 1),
                actions: .init(), mediaContext: context))
        #if os(macOS)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 320),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
            let document = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 1800))
            scroll.documentView = document
            document.addSubview(media)
            window.contentView?.addSubview(scroll)
            NSApplication.shared.unhide(nil)
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            defer { window.close() }
            for _ in 0..<50 {
                if NSApp.isActive, window.occlusionState.contains(.visible) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try XCTSkipUnless(
                NSApp.isActive && window.occlusionState.contains(.visible),
                "Sticker lifecycle tests require an active, visible AppKit window")
            window.contentView?.layoutSubtreeIfNeeded()
        #else
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
            scroll.addSubview(media)
            window.layoutIfNeeded()
        #endif
        defer { media.clear() }
        func findSurface(in view: StickerNativeView) -> StickerMediaSurfaceView? {
            (view as? StickerMediaSurfaceView)
                ?? view.subviews.compactMap { findSurface(in: $0) }.first
        }
        let surface = try XCTUnwrap(findSurface(in: media))
        let renderer = try XCTUnwrap(
            surface.subviews.compactMap { $0 as? TimelineImageView }.first)
        media.setVisible(true)
        #if os(macOS)
            media.layoutSubtreeIfNeeded()
        #else
            media.layoutIfNeeded()
        #endif
        XCTAssertEqual(fixture.requestCount, 0)
        context.setNetworkAuthorized(false)

        // The native tile was configured outside the viewport, unlike a picker's
        // SwiftUI onAppear. Ancestor scrolling must wake the same sticker without
        // another bind, setVisible, or layout call from the row.
        #if os(macOS)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 1160))
            scroll.reflectScrolledClipView(scroll.contentView)
        #else
            scroll.setContentOffset(CGPoint(x: 0, y: 1160), animated: false)
        #endif
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.requestCount, 0, "Visibility must not bypass account authorization")
        context.setNetworkAuthorized(true)
        await fulfillment(of: [requested], timeout: 2)
        #if os(macOS)
            let spinner = try XCTUnwrap(
                renderer.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        #else
            let spinner = try XCTUnwrap(
                renderer.subviews.compactMap { $0 as? UIActivityIndicatorView }.first)
        #endif
        XCTAssertFalse(
            spinner.isHidden,
            "A visible pending sticker must not be blank without loading chrome")
        let available = expectation(description: "The visible sticker draws its downloaded pixels")
        renderer.onImageAvailabilityChanged = { if $0 { available.fulfill() } }
        fixture.resume()
        await fulfillment(of: [available], timeout: 2)
        XCTAssertEqual(fixture.requestCount, 1)
        #if os(macOS)
            renderer.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(
                renderer.bitmapImageRepForCachingDisplay(in: renderer.bounds))
            renderer.cacheDisplay(in: renderer.bounds, to: bitmap)
            let pixels = try XCTUnwrap(bitmap.cgImage)
            let attachment = XCTAttachment(
                data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                uniformTypeIdentifier: "public.png")
        #else
            renderer.layoutIfNeeded()
            renderer.layer.displayIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: renderer.bounds).image {
                renderer.layer.render(in: $0.cgContext)
            }
            let pixels = try XCTUnwrap(image.cgImage)
            let attachment = XCTAttachment(image: image)
        #endif
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
        XCTAssertTrue(spinner.isHidden)
        attachment.name = "Native sticker loaded without opening the picker"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
