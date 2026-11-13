import ChahuaAPI
import SwiftUI
import XCTest

@testable import chahua_apple

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
final class FriendRequestProfileContextTests: XCTestCase {
    func testExplicitDirectionWinsAndMissingDirectionUsesRecipient() throws {
        let cases: [(String?, Int32, Int32)] = [
            ("incoming", 2, 2), ("outgoing", 1, 1), (nil, 1, 2), (nil, 2, 1),
        ]
        for (direction, currentUserID, peerUID) in cases {
            let context = FriendRequestProfileContext(
                request: try request(direction: direction), currentUserID: currentUserID)
            XCTAssertEqual(context.peerUID, peerUID)
        }
    }

    func testEveryHistoricalStatusPreservesFullVerificationSnapshot() throws {
        let question = "Original question\nSecond line\n第三行"
        let message = "Full answer\n\nIncluding spacing and **literal markdown**"
        for status in ["pending", "archived", "accepted", "rejected"] {
            for direction in ["incoming", "outgoing"] {
                let context = FriendRequestProfileContext(
                    request: try request(
                        status: status, direction: direction, question: question, message: message),
                    currentUserID: 1)
                XCTAssertEqual(context.id, "request-one")
                XCTAssertEqual(context.question, question)
                XCTAssertEqual(context.message, message)
            }
        }
    }

    func testDifferentRequestsForSamePeerKeepDistinctRouteIdentityAndContent() throws {
        let first = FriendRequestProfileContext(
            request: try request(id: "first", question: "Old question", message: "Old answer"),
            currentUserID: 1)
        let second = FriendRequestProfileContext(
            request: try request(id: "second", question: "New question", message: "New answer"),
            currentUserID: 1)
        XCTAssertEqual(first.peerUID, second.peerUID)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set([first, second]).count, 2)
        XCTAssertEqual(first.question, "Old question")
        XCTAssertEqual(first.message, "Old answer")
    }

    func testAbsentAndEmptyMessagesRemainFaithfulToSelectedRequest() throws {
        for message in [nil, ""] as [String?] {
            let context = FriendRequestProfileContext(
                request: try request(question: nil, message: message), currentUserID: 1)
            XCTAssertNil(context.question)
            XCTAssertEqual(context.message, message)
        }
    }

    func testProfileContextIsAbsentForGenericWrongPeerAndChangedAccountOrSession() throws {
        let store = try store()
        defer { store.reset() }
        let context = FriendRequestProfileContext(request: try request(), currentUserID: 1)
        let generic = UserProfileView(uid: 2, currentUserID: 1, store: store, onOpenChat: { _ in })
        XCTAssertNil(generic.visibleRequestContext)
        let wrongPeer = UserProfileView(
            uid: 3, currentUserID: 1, store: store, requestContext: context, onOpenChat: { _ in })
        XCTAssertNil(wrongPeer.visibleRequestContext)
        let detail = UserProfileView(
            uid: 2, currentUserID: 1, store: store, requestContext: context, onOpenChat: { _ in })
        XCTAssertEqual(detail.visibleRequestContext, context)
        store.currentUserProfile = try profile(uid: 3)
        XCTAssertNil(detail.visibleRequestContext)
        store.currentUserProfile = try profile(uid: 1)
        store.reset()
        store.currentUserProfile = try profile(uid: 1)
        XCTAssertNil(
            detail.visibleRequestContext, "Reauthentication must not reveal an old request snapshot"
        )
    }

    func testNativeRequestDetailsRemainVisibleWhenProfileHydrationFails() async throws {
        let store = try store()
        defer { store.reset() }
        let context = FriendRequestProfileContext(
            request: try request(
                status: "accepted", question: "Historical question\nSecond question line",
                message: "Historical answer\nSecond answer line\n第三行"), currentUserID: 1)
        let root = UserProfileView(
            uid: 2, currentUserID: 1, store: store, requestContext: context, onOpenChat: { _ in })
        #if os(macOS)
            let host = NSHostingController(rootView: root.frame(width: 560, height: 700))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 560, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.makeKeyAndOrderFront(nil)
            defer {
                window.contentViewController = nil
                window.close()
            }
        #else
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let host = UIHostingController(rootView: root)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
        #endif
        // FakeChatAPI's unsupported profile search fails locally; no production service is used.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(root.visibleRequestContext, context)
        #if os(macOS)
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(
                host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let image = NSImage(size: host.view.bounds.size)
            image.addRepresentation(bitmap)
        #else
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
        #endif
        let attachment = XCTAttachment(image: image)
        attachment.name = "Request verification details survive profile hydration failure"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func request(
        id: String = "request-one", status: String = "pending", direction: String? = nil,
        question: String? = "Original question", message: String? = "Original answer"
    ) throws -> FriendRequest {
        var object: [String: Any] = [
            "id": id, "from": ["uid": 2, "username": "Peer", "gender": 0],
            "to": ["uid": 1, "username": "Me", "gender": 0],
            "createdAt": "2026-09-01T00:00:00Z", "status": status,
        ]
        object["direction"] = direction
        object["question"] = question
        object["message"] = message
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            FriendRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func profile(uid: Int32) throws -> MeResponse {
        try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                "{\"uid\":\(uid),\"username\":\"Me\",\"gender\":2,\"stickerPackOrder\":[],\"permissions\":[]}"
                    .utf8))
    }

    private func store() throws -> ChatStore {
        let api = FakeChatAPI()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        store.currentUserProfile = try profile(uid: 1)
        return store
    }
}
