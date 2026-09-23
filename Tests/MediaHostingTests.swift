import ChahuaAPI
import Kingfisher
import SwiftUI
import XCTest

@testable import chahua_apple

@MainActor
final class MediaHostingTests: XCTestCase {
    func testPreparingGeometryDoesNotAcquireRemoteAvatars() async throws {
        let requested = expectation(description: "Geometry preparation must not request an avatar")
        requested.isInverted = true
        let fixture = MediaImageFixture(
            data: try makeMediaPNG(red: 255, green: 0, blue: 255),
            onRequest: { requested.fulfill() })
        MediaImageURLProtocol.install(fixture)
        defer { MediaImageURLProtocol.remove(fixture) }
        let message = try TimelineTestFixtures.message(
            id: "hosted-avatar", senderID: 2, at: 0,
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
            row: row, currentUserProfile: nil, currentUserID: 1, isThreadTimeline: false,
            environment: environment)
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
