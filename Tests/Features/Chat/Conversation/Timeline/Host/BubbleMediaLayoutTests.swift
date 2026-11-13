import ChahuaAPI
import Foundation
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
final class BubbleMediaLayoutTests: XCTestCase {
    func testNativeMixedMediaLoadsAndOpensServerAndBorrowedLocalSlotsInOrder() async throws {
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 0))
        MediaImageURLProtocol.install(fixture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localURL = directory.appendingPathComponent("borrowed.png")
        let localData = try makeMediaPNG(red: 0, green: 0, blue: 255)
        try localData.write(to: localURL)
        let cache = try ImageCache(name: UUID().uuidString, cacheDirectoryURL: directory)
        let downloader = ImageDownloader(name: UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaImageURLProtocol.self]
        downloader.sessionConfiguration = configuration
        let context = AppMediaContext(cache: cache, downloader: downloader)
        let local = LocalOutgoingAttachment(
            id: "local", generation: "generation", position: 0,
            sourcePath: localURL.path, previewPath: localURL.path, fileName: "borrowed.png",
            mimeType: "image/png", width: 16, height: 16, byteCount: Int64(localData.count))
        let server = AttachmentResponse(
            id: "server", url: fixture.url.absoluteString, kind: "image/png", size: 1,
            fileName: "server.png", width: 16, height: 16)
        var pending = TimelineTestFixtures.pending(id: "mixed-native", claimed: true)
        pending.attachments = [local]
        pending.intentAttachments = [.server(server), .local(local)]
        let row = TimelineRow.message(
            .init(
                entry: .pending(pending), isOutgoing: true, groupPosition: .middle,
                showsSenderName: false))
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 400)
        let presentation = TimelineRowPresentation.make(
            row: row, currentUserID: 1, isThreadTimeline: false, environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        let frame = try XCTUnwrap(layout.frames[.media])
        let media = TimelineMediaView(frame: CGRect(origin: .zero, size: frame.size))
        var opened: [MessageImageGallery] = []
        media.bind(
            .init(
                presentation: presentation, layout: layout, context: .init(currentUserID: 1),
                actions: .init(openMedia: { opened.append($0) }), mediaContext: context))
        #if os(macOS)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 420, height: 460),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(media)
            window.orderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            func images(in view: NSView) -> [TimelineImageView] {
                (view as? TimelineImageView).map { [$0] }
                    ?? view.subviews.flatMap { images(in: $0) }
            }
        #else
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            window.rootViewController = controller
            controller.view.addSubview(media)
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            func images(in view: UIView) -> [TimelineImageView] {
                (view as? TimelineImageView).map { [$0] }
                    ?? view.subviews.flatMap { images(in: $0) }
            }
        #endif
        defer {
            media.clear()
            #if os(macOS)
                window.close()
            #else
                window.isHidden = true
                window.rootViewController = nil
            #endif
            MediaImageURLProtocol.remove(fixture)
            cache.clearCache()
            try? FileManager.default.removeItem(at: directory)
        }
        let imageViews = images(in: media)
        XCTAssertEqual(imageViews.count, 2)
        let loaded = expectation(description: "Both native mixed-selection thumbnails load")
        loaded.expectedFulfillmentCount = 2
        for image in imageViews {
            var didLoad = false
            image.onImageAvailabilityChanged = { available in
                guard available, !didLoad else { return }
                didLoad = true
                loaded.fulfill()
            }
        }
        media.setVisible(true)
        await fulfillment(of: [loaded], timeout: 4)
        XCTAssertEqual(fixture.requestCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        #if os(macOS)
            for tile in media.subviews.compactMap({ $0 as? NSButton }) { tile.performClick(nil) }
            let bitmap = try XCTUnwrap(media.bitmapImageRepForCachingDisplay(in: media.bounds))
            media.cacheDisplay(in: media.bounds, to: bitmap)
            let capture = XCTAttachment(
                data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                uniformTypeIdentifier: "public.png")
        #else
            for tile in media.subviews.compactMap({ $0 as? UIControl }) {
                tile.sendActions(for: .touchUpInside)
            }
            let capture = XCTAttachment(
                image: UIGraphicsImageRenderer(bounds: media.bounds).image { _ in
                    media.drawHierarchy(in: media.bounds, afterScreenUpdates: true)
                })
        #endif
        XCTAssertEqual(opened.map(\.selectedIndex), [0, 1])
        XCTAssertEqual(opened.first?.items.map(\.id), ["server", "local"])
        XCTAssertEqual(opened.first?.items.first?.url, fixture.url)
        XCTAssertEqual(opened.last?.items.last?.url, localURL)
        capture.name = "Queued latest intent: server thumbnail then borrowed local thumbnail"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testMixedPendingSelectionKeepsOrderDimensionsAndNativeGallerySources() throws {
        let server = try attachment(id: "server", width: 640, height: 480)
        let local = LocalOutgoingAttachment(
            id: "local", generation: "generation", position: 0,
            sourcePath: "/tmp/local.png", previewPath: "/tmp/local-preview.png",
            fileName: "local.png", mimeType: "image/png", width: 300, height: 600, byteCount: 1)
        var pending = TimelineTestFixtures.pending(id: "mixed", claimed: true)
        pending.attachments = [local]
        pending.intentAttachments = [.server(server), .local(local)]
        let entry = ConversationTimelineEntry.pending(pending)
        XCTAssertEqual(entry.mediaAttachments.map(\.id), ["server", "local"])
        XCTAssertEqual(
            entry.mediaAttachments.map(\.mediaDimensions),
            [CGSize(width: 640, height: 480), CGSize(width: 300, height: 600)])
        let gallery = try XCTUnwrap(
            BubbleMediaLayout.gallery(for: entry.mediaAttachments, availableWidth: 300))
        XCTAssertEqual(gallery.cells.map(\.attachment.id), ["server", "local"])
        let viewer = try XCTUnwrap(MessageImageGallery(entry: entry, attachmentIndex: 1))
        XCTAssertEqual(viewer.messageID, "mixed")
        XCTAssertEqual(viewer.items.map(\.id), ["server", "local"])
        XCTAssertEqual(viewer.items[0].url?.absoluteString, server.url)
        XCTAssertEqual(viewer.items[1].url, URL(fileURLWithPath: local.uploadPath))
        XCTAssertEqual(viewer.selectedIndex, 1)
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 400)
        let presentation = TimelineRowPresentation.make(
            row: .message(
                .init(
                    entry: entry, isOutgoing: true, groupPosition: .single,
                    showsSenderName: false)),
            currentUserID: 1, isThreadTimeline: false, environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        XCTAssertNotNil(layout.frames[.media])
        XCTAssertEqual(layout.mediaFrames.count, 2)
        XCTAssertTrue(
            presentation.layoutKey.sections.contains(
                .media(entry.mediaAttachments.map(\.mediaDimensions), category: "gallery")))
    }

    func testExplicitlyEmptyPendingSelectionNeverFallsBackToOrdinarySlots() throws {
        let local = LocalOutgoingAttachment(
            id: "local", generation: "generation", position: 0,
            sourcePath: "/tmp/local.png", previewPath: "/tmp/local.png",
            fileName: "local.png", mimeType: "image/png", width: 100, height: 100, byteCount: 1)
        var pending = TimelineTestFixtures.pending(id: "empty")
        pending.attachments = [local]
        XCTAssertEqual(ConversationTimelineEntry.pending(pending).mediaAttachments, [.local(local)])
        pending.intentAttachments = []
        let entry = ConversationTimelineEntry.pending(pending)
        XCTAssertTrue(entry.mediaAttachments.isEmpty)
        XCTAssertNil(MessageImageGallery(entry: entry, attachmentIndex: 0))
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 400)
        let presentation = TimelineRowPresentation.make(
            row: .message(
                .init(
                    entry: entry, isOutgoing: true, groupPosition: .single,
                    showsSenderName: false)),
            currentUserID: 1, isThreadTimeline: false, environment: environment)
        XCTAssertNil(
            TimelineLayoutEngine().layout(presentation, environment: environment).frames[.media])
    }

    func testSmallImagesUpscaleWithoutExceedingTheAvailableLane() throws {
        let image = try attachment(id: "small", width: 40, height: 40)
        let size = try XCTUnwrap(BubbleMediaLayout.singleSize(for: image, availableWidth: 300))
        XCTAssertEqual(size.width, 120, accuracy: 0.001)
        XCTAssertEqual(size.height, 120, accuracy: 0.001)
        let narrow = try XCTUnwrap(BubbleMediaLayout.singleSize(for: image, availableWidth: 30))
        XCTAssertLessThanOrEqual(narrow.width, 30)
        XCTAssertLessThanOrEqual(narrow.height, 40)
    }

    func testInvalidGalleryDimensionsUseTheSameFallbackAsMissingDimensions() throws {
        let missing = [
            try attachment(id: "a", width: nil, height: 100),
            try attachment(id: "b", width: 200, height: 100),
        ]
        let invalid = [
            try attachment(id: "a", width: -3, height: 100),
            try attachment(id: "b", width: 200, height: 100),
        ]
        let expected = try XCTUnwrap(BubbleMediaLayout.gallery(for: missing, availableWidth: 300))
        let actual = try XCTUnwrap(BubbleMediaLayout.gallery(for: invalid, availableWidth: 300))
        XCTAssertEqual(actual.cells.map(\.frame), expected.cells.map(\.frame))
    }

    func testAsymmetricGalleryChoosesBalancedRowsAndPreservesOrdering() throws {
        let dimensions = [(250, 100), (50, 100), (150, 100), (75, 100), (200, 100), (50, 100)]
        let images = try dimensions.enumerated().map { index, dimensions in
            try attachment(id: String(index), width: dimensions.0, height: dimensions.1)
        }
        let gallery = try XCTUnwrap(BubbleMediaLayout.gallery(for: images, availableWidth: 300))
        for cell in gallery.cells {
            XCTAssertTrue(
                CGRect(origin: .zero, size: gallery.size).insetBy(dx: -0.001, dy: -0.001).contains(
                    cell.frame))
        }
        XCTAssertLessThanOrEqual(gallery.size.height, 400)
    }

    func testGalleryCapacityKeepsOverflowInTheSixthVisibleTile() throws {
        for count in [2, 3, 4, 5, 6, 7, 20] {
            let images = try (0..<count).map {
                try attachment(id: String($0), width: 100 + $0 * 40, height: 200)
            }
            let gallery = try XCTUnwrap(BubbleMediaLayout.gallery(for: images, availableWidth: 300))
            XCTAssertEqual(gallery.cells.map(\.attachment.id), (0..<min(count, 6)).map(String.init))
            XCTAssertEqual(gallery.cells.last?.overflowCount, count > 6 ? count - 5 : 0)
            for cell in gallery.cells {
                XCTAssertGreaterThan(cell.frame.width, 0)
                XCTAssertGreaterThan(cell.frame.height, 0)
                XCTAssertLessThanOrEqual(cell.frame.maxX, 300.001)
                XCTAssertLessThanOrEqual(cell.frame.maxY, 400.001)
            }
        }
    }

    private func attachment(id: String, width: Int?, height: Int?) throws -> AttachmentResponse {
        let object: [String: Any] = [
            "id": id, "url": "https://example.invalid/\(id).png", "kind": "image/png", "size": 1,
            "fileName": "\(id).png", "width": width as Any? ?? NSNull(),
            "height": height as Any? ?? NSNull(),
        ]
        return try JSONDecoder().decode(
            AttachmentResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
