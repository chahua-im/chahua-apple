import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class TimelineLayoutPreparationTests: XCTestCase {
    func testAppendRebuildsOnlyTheNewRowAndItsRegroupedNeighbor() throws {
        let cache = TimelineRowCache(currentUserID: 1, isThreadTimeline: false)
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
        let earlier = try (1...3).map {
            try TimelineTestFixtures.message(id: UInt64($0), senderID: 2, at: $0)
        }
        let before = try prepare(rows(earlier), environment: environment, cache: cache)

        let appended = earlier + [try TimelineTestFixtures.message(id: 4, senderID: 2, at: 4)]
        let afterRows = rows(appended)
        let after = try prepare(afterRows, environment: environment, cache: cache)

        // The previous tail changes from .last to .middle; everything above it is unchanged.
        let tail = TimelineRowID.message(earlier[2].timelineStableKey)
        let added = TimelineRowID.message(appended[3].timelineStableKey)
        for row in afterRows where row.id != tail && row.id != added {
            XCTAssertTrue(
                try XCTUnwrap(after[row.id]) === before[row.id], "\(row.id) must be reused")
        }
        XCTAssertFalse(try XCTUnwrap(after[tail]) === before[tail])
        guard case .message(let regrouped) = try XCTUnwrap(after[tail]).row else {
            return XCTFail("Expected a message row")
        }
        XCTAssertEqual(regrouped.groupPosition, .middle)
        XCTAssertNotNil(after[added])
        XCTAssertNil(before[added])

        let resized = try prepare(
            afterRows, environment: .current(timelineWidth: 400), cache: cache)
        for row in afterRows {
            XCTAssertFalse(
                try XCTUnwrap(resized[row.id]) === after[row.id], "\(row.id) must be rebuilt")
        }
    }

    private func rows(_ messages: [MessageResponse]) -> [TimelineRow] {
        TimelineRowsBuilder(
            currentUserID: 1, calendar: Calendar(identifier: .gregorian)
        ).build(messages)
    }

    /// Few changes must complete in one display turn.
    private func prepare(
        _ rows: [TimelineRow], environment: TimelineLayoutEnvironment, cache: TimelineRowCache
    ) throws -> [TimelineRowID: PreparedRow] {
        let preparation = TimelineLayoutPreparation(
            snapshot: .init(
                revision: 0, windowRevision: 0, rows: rows, animateFollowing: false,
                pendingScroll: nil),
            environment: environment, cache: cache)
        XCTAssertTrue(preparation.advance(cache: cache))
        return preparation.rows
    }
}
