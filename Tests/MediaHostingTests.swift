import ChahuaAPI
import CoreGraphics
import SwiftUI
import XCTest
@testable import ChahuaMediaCache
@testable import chahua_apple

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
final class MediaHostingTests: XCTestCase {
    func testHostedAvatarLoadsAndChangesWithEnvironmentContext() async throws {
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255))
        MediaImageURLProtocol.install(fixture)
        defer { MediaImageURLProtocol.remove(fixture) }
        let message = try message(avatarURL: fixture.url)
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true,
            source: MediaHostingSource(page: try TimelineTestFixtures.page([message])),
            messageStore: ConversationMessageStore()
        )
        await model.loadInitial()
        let firstContext = makeContext()
        let first = try await firstContext.resources(for: firstContext.activationID)
        let makeRoot = { (context: AppMediaContext?) in
            ConversationTimelineView(model: model).environment(\.mediaContext, context)
        }

        #if os(macOS)
        let host = NSHostingController(rootView: makeRoot(firstContext))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 480, height: 400))
        window.orderFront(nil)
        defer { window.close() }
        #elseif os(iOS)
        let host = UIHostingController(rootView: makeRoot(firstContext))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        #endif

        try await waitForColor(red: 255, green: 0, blue: 255) { try self.snapshot(host.view) }
        let firstUsage = try await first.cache.usage()
        XCTAssertEqual(firstUsage.byTag[CacheTag(rawValue: "avatars")]?.completeItemCount, 1)
        XCTAssertEqual(fixture.requestCount, 1)

        fixture.replaceBody(try makeMediaPNG(red: 0, green: 255, blue: 0))
        let secondContext = makeContext()
        let second = try await secondContext.resources(for: secondContext.activationID)
        host.rootView = makeRoot(secondContext)

        try await waitForColor(red: 0, green: 255, blue: 0) { try self.snapshot(host.view) }
        let secondUsage = try await second.cache.usage()
        XCTAssertEqual(secondUsage.byTag[CacheTag(rawValue: "avatars")]?.completeItemCount, 1)
        XCTAssertEqual(fixture.requestCount, 2,
                       "Replacing the environment context must refresh existing native cell roots.")
    }

    func testMeasurementRootsDoNotAcquireRemoteAvatars() async throws {
        let requested = expectation(description: "Measurement must not request a remote avatar")
        requested.isInverted = true
        let fixture = MediaImageFixture(
            data: try makeMediaPNG(red: 255, green: 0, blue: 255),
            onRequest: { requested.fulfill() }
        )
        MediaImageURLProtocol.install(fixture)
        defer { MediaImageURLProtocol.remove(fixture) }
        let context = makeContext()
        let resources = try await context.resources(for: context.activationID)
        let row = TimelineRow.message(.init(
            entry: .remote(try message(avatarURL: fixture.url)),
            isOutgoing: false, groupPosition: .single, showsSenderName: true
        ))

        #if os(macOS)
        let parent = NSHostingController(rootView: Color.clear.environment(\.mediaContext, context))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        window.orderFront(nil)
        defer { window.close() }
        let measurer = TimelineRowMeasurer(parent: parent)
        _ = measurer.height(for: row, width: 400, context: .init())
        parent.view.layoutSubtreeIfNeeded()
        #elseif os(iOS)
        let parent = UIHostingController(rootView: Color.clear.environment(\.mediaContext, context))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let measurer = TimelineRowMeasurer(parent: parent)
        _ = measurer.height(for: row, width: 400, context: .init())
        parent.view.layoutIfNeeded()
        #endif

        await fulfillment(of: [requested], timeout: 0.2)
        let usage = try await resources.cache.usage()
        XCTAssertEqual(usage.total.itemCount, 0)
        XCTAssertEqual(fixture.requestCount, 0)
    }

    private func makeContext() -> AppMediaContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chahua-media-hosting-\(UUID().uuidString)", isDirectory: true)
        let context = AppMediaContext(rootDirectory: directory, namespace: "hosting-tests") { configuration in
            try await MediaCache(configuration: configuration,
                                 protocolClasses: [MediaImageURLProtocol.self], clock: { Date() })
        }
        addTeardownBlock { @MainActor in
            context.activate(uid: nil)
            _ = try? await context.resources(for: context.activationID)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        context.activate(uid: 1)
        return context
    }

    private func message(avatarURL: URL) throws -> MessageResponse {
        let base = try TimelineTestFixtures.message(id: "hosted-avatar", senderID: 2, at: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(base)) as? [String: Any])
        var sender = try XCTUnwrap(object["sender"] as? [String: Any])
        sender["avatarUrl"] = avatarURL.absoluteString
        object["sender"] = sender
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MessageResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func waitForColor(
        red: UInt8, green: UInt8, blue: UInt8, snapshot: () throws -> CGImage
    ) async throws {
        for _ in 0 ..< 100 {
            if try containsColor(snapshot(), red: red, green: green, blue: blue) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The remote avatar pixels did not appear in the native hosted timeline.")
    }

    private func containsColor(_ image: CGImage, red: UInt8, green: UInt8, blue: UInt8) throws -> Bool {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(
                data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = storage.bindMemory(to: UInt8.self)
            var matches = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                if abs(Int(bytes[index]) - Int(red)) < 8,
                   abs(Int(bytes[index + 1]) - Int(green)) < 8,
                   abs(Int(bytes[index + 2]) - Int(blue)) < 8,
                   bytes[index + 3] > 247 {
                    matches += 1
                    if matches >= 64 { return true }
                }
            }
            return false
        }
    }

    #if os(macOS)
    private func snapshot(_ view: NSView) throws -> CGImage {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.cgImage)
    }
    #elseif os(iOS)
    private func snapshot(_ view: UIView) throws -> CGImage {
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(image.cgImage)
    }
    #endif
}

@MainActor
private final class MediaHostingSource: TimelineMessageSource {
    let page: ListMessagesResponse

    init(page: ListMessagesResponse) { self.page = page }

    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        page
    }
}
