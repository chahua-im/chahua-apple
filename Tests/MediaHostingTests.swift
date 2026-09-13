import ChahuaAPI
import XCTest
@testable import chahua_apple

@MainActor
final class MediaHostingTests: XCTestCase {
    func testPreparingGeometryDoesNotAcquireRemoteAvatars() async throws {
        let requested = expectation(description: "Geometry preparation must not request an avatar")
        requested.isInverted = true
        let fixture = MediaImageFixture(data: try makeMediaPNG(red: 255, green: 0, blue: 255), onRequest: { requested.fulfill() })
        MediaImageURLProtocol.install(fixture)
        defer { MediaImageURLProtocol.remove(fixture) }
        let message = try TimelineTestFixtures.message(id: "hosted-avatar", senderID: 2, at: 0, fields: [
            "sender": ["uid": 2, "gender": 0, "name": "Remote sender", "avatarUrl": fixture.url.absoluteString]
        ])
        let row = TimelineRow.message(.init(entry: .remote(message), isOutgoing: false, groupPosition: .single, showsSenderName: true))
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 400)
        let presentation = TimelineRowPresentation.make(row: row, currentUserProfile: nil, currentUserID: 1, isThreadTimeline: false, environment: environment)
        let cache = TimelineLayoutCache()
        let layout = cache.layout(for: presentation, environment: environment)
        XCTAssertNotNil(layout.frames[.avatar])
        await fulfillment(of: [requested], timeout: 0.2)
        XCTAssertEqual(fixture.requestCount, 0)
    }
}
