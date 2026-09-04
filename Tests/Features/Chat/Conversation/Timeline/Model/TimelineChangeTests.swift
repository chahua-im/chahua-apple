import Foundation
import XCTest
@testable import chahua_apple

@MainActor
final class TimelineChangeTests: XCTestCase {
    func testPrependReloadsPriorFirstMessageWhenItsGroupingChanges() throws {
        let builder = makeBuilder()
        let old = builder.build([
            try TimelineTestFixtures.message(id: "2", senderID: 2, at: 10),
        ])
        let new = builder.build([
            try TimelineTestFixtures.message(id: "1", senderID: 2, at: 0),
            try TimelineTestFixtures.message(id: "2", senderID: 2, at: 10),
        ])

        XCTAssertEqual(
            TimelineChange.compute(from: old, to: new),
            .incremental(
                removals: [],
                insertions: IndexSet(integer: 1),
                reloads: IndexSet(integer: 2)
            )
        )
    }

    func testRemovalUsesOldRowIndex() throws {
        let builder = makeBuilder()
        let old = builder.build([
            try TimelineTestFixtures.message(id: "1", at: 0),
            try TimelineTestFixtures.message(id: "2", at: 10),
        ])
        let new = builder.build([
            try TimelineTestFixtures.message(id: "2", at: 10),
        ])
        XCTAssertEqual(
            TimelineChange.compute(from: old, to: new),
            .incremental(removals: IndexSet(integer: 1), insertions: [], reloads: IndexSet(integer: 1))
        )
    }

    func testIdenticalRowsProduceEmptyIncrementalChange() throws {
        let rows = makeBuilder().build([
            try TimelineTestFixtures.message(id: "1", at: 0),
        ])

        XCTAssertTrue(TimelineChange.compute(from: rows, to: rows).isEmpty)
    }

    private func makeBuilder() -> TimelineRowsBuilder {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return TimelineRowsBuilder(currentUserID: 1, isGroupChat: true, calendar: calendar)
    }
}
