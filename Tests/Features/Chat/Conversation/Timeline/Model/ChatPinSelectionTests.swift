import ChahuaAPI
import XCTest
@testable import chahua_apple

@MainActor
final class ChatPinSelectionTests: XCTestCase {
    func testViewportSelectsNearestOlderPinIncludingExactBoundary() throws {
        let pins = try [30, 20, 10].map { second in
            PinResponse(id: "pin-\(second)", chatId: "chat",
                        message: try TimelineTestFixtures.message(id: "\(second)", at: second),
                        pinnedBy: 1, pinnedAt: TimelineTestFixtures.date(second: 40))
        }
        XCTAssertNil(ChatPinSelection.activePin(in: [], bottomVisibleMessageDate: nil))
        XCTAssertEqual(ChatPinSelection.activePin(in: pins, bottomVisibleMessageDate: nil)?.id, "pin-30")
        XCTAssertEqual(ChatPinSelection.activePin(in: pins, bottomVisibleMessageDate: pins[1].message.createdAt)?.id, "pin-20")
        XCTAssertEqual(ChatPinSelection.activePin(in: pins, bottomVisibleMessageDate: pins[1].message.createdAt.addingTimeInterval(-1))?.id, "pin-10")
        XCTAssertEqual(ChatPinSelection.activePin(in: pins, bottomVisibleMessageDate: pins[2].message.createdAt.addingTimeInterval(-1))?.id, "pin-10")
    }
}
