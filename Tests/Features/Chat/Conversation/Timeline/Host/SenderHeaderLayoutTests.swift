import ChahuaAPI
import SwiftUI
import XCTest
#if os(macOS)
import AppKit
private typealias SenderHeaderFont = NSFont
#elseif os(iOS)
import UIKit
private typealias SenderHeaderFont = UIFont
#endif
@testable import chahua_apple

@MainActor
final class SenderHeaderLayoutTests: XCTestCase {
    #if os(macOS)
    func testOutgoingSenderNameRendersWhiteInBothAppearances() throws {
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 600, captionSize: 24)
        let presentation = try presentation(name: "Wei", gender: 1, outgoing: true, environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        let title = try XCTUnwrap(presentation.title)
        for scheme in [ColorScheme.light, .dark] {
            let native = TimelineBubbleContentView(frame: CGRect(origin: .zero, size: try XCTUnwrap(layout.frames[.bubble]).size))
            native.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            native.bind(.init(presentation: presentation, layout: layout, context: .init(), actions: .init(), mediaContext: nil))
            native.layoutSubtreeIfNeeded()
            func senderLabel(in view: NSView) -> NSTextField? {
                if let label = view as? NSTextField, label.stringValue == title.name { return label }
                return view.subviews.lazy.compactMap { senderLabel(in: $0) }.first
            }
            let label = try XCTUnwrap(senderLabel(in: native))
            let bitmap = try XCTUnwrap(label.bitmapImageRepForCachingDisplay(in: label.bounds))
            label.cacheDisplay(in: label.bounds, to: bitmap)
            var whiteInk = 0
            var coloredInk = 0
            for y in 0 ..< bitmap.pixelsHigh {
                for x in 0 ..< bitmap.pixelsWide {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.5 else { continue }
                    let channels = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
                    let brightest = channels.max()!
                    let darkest = channels.min()!
                    if brightest > 0.8 && brightest - darkest < 0.02 { whiteInk += 1 }
                    if brightest > 0.2 && brightest - darkest > 0.1 { coloredInk += 1 }
                }
            }
            XCTAssertGreaterThan(whiteInk, 0, "The outgoing name must have visible white glyphs.")
            XCTAssertEqual(coloredInk, 0, "Per-user tint must not color outgoing sender text.")
        }
    }
    func testMeasuredHeaderRendersSameGlyphsAsUnconstrainedLabels() throws {
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 900, displayScale: 2)
        let presentation = try presentation(name: "frogeater", gender: 1, environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        let native = TimelineBubbleContentView(frame: CGRect(origin: .zero, size: try XCTUnwrap(layout.frames[.bubble]).size))
        native.bind(.init(presentation: presentation, layout: layout, context: .init(), actions: .init(), mediaContext: nil))
        native.layoutSubtreeIfNeeded()
        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { child in
                (child as? NSTextField).map { [$0] } ?? labels(in: child)
            }
        }
        let renderedLabels = labels(in: native)
        for text in ["frogeater", "程序员", "♂"] {
            let label = try XCTUnwrap(renderedLabels.first { $0.stringValue == text })
            func ink() throws -> [Bool] {
                let bitmap = try XCTUnwrap(label.bitmapImageRepForCachingDisplay(in: label.bounds))
                label.cacheDisplay(in: label.bounds, to: bitmap)
                return (0 ..< bitmap.pixelsHigh).flatMap { y in
                    (0 ..< bitmap.pixelsWide).map { x in
                        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
                    }
                }
            }
            let width = label.frame.width
            let measuredInk = try ink().filter { $0 }.count
            label.frame.size.width = width + 200
            label.needsDisplay = true
            let unconstrainedInk = try ink().filter { $0 }.count
            XCTAssertGreaterThan(measuredInk, 0)
            XCTAssertEqual(measuredInk, unconstrainedInk,
                           "\(label.stringValue) must not acquire an ellipsis at its measured width.")
        }
    }

    #endif

    func testQueuedSenderUsesLiveProfileUntilAcknowledgement() throws {
        let profile = try JSONDecoder().decode(MeResponse.self, from: Data(#"""
        {
          "uid": 1, "username": "Local name", "gender": 2, "stickerPackOrder": [], "permissions": [],
          "userGroup": {"groupId": 7, "name": "Staff", "chatGroupColor": "#112233", "chatGroupColorDark": "#aabbcc"}
        }
        """#.utf8))
        let pending = PendingOutgoingMessage(
            chatID: "chat", clientGeneratedID: "queued-sender",
            body: .init(messageType: .text, clientGeneratedId: "queued-sender", message: "Hi"),
            enqueuedAt: TimelineTestFixtures.date(second: 0), senderID: 1, state: .queued
        )
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
        func make(_ entry: ConversationTimelineEntry, profile: MeResponse?) -> TimelineRowPresentation {
            TimelineRowPresentation.make(
                row: .message(.init(entry: entry, isOutgoing: true, groupPosition: .single, showsSenderName: true)),
                currentUserProfile: profile, currentUserID: 1, isThreadTimeline: false, environment: environment
            )
        }

        XCTAssertEqual(make(.pending(pending), profile: nil).title?.name, "User 1")
        let queued = try XCTUnwrap(make(.pending(pending), profile: profile).title)
        XCTAssertEqual(queued.name, "Local name")
        XCTAssertEqual(queued.genderGlyph, "♀")
        XCTAssertEqual(queued.groupName, "Staff")
        XCTAssertEqual(queued.userGroup?.chatGroupColor, "#112233")
        XCTAssertEqual(queued.userGroup?.chatGroupColorDark, "#aabbcc")

        let acknowledgement = try TimelineTestFixtures.message(
            id: "confirmed-sender", senderID: 1, at: 0, clientGeneratedID: pending.clientGeneratedID,
            fields: ["sender": ["uid": 1, "gender": 1, "name": "", "userGroup": NSNull()]]
        )
        let confirmed = try XCTUnwrap(make(.remote(acknowledgement), profile: profile).title)
        XCTAssertEqual(confirmed.name, "User 1", "An empty authoritative name must not resurrect the local profile name.")
        XCTAssertEqual(confirmed.genderGlyph, "♂")
        XCTAssertNil(confirmed.groupName)
        XCTAssertNil(confirmed.userGroup)
    }

    func testLegacyProfileWithoutGroupDoesNotStyleAnotherSender() throws {
        let profile = try JSONDecoder().decode(MeResponse.self, from: Data(#"""
        {"uid": 1, "username": "Local name", "gender": 2, "stickerPackOrder": [], "permissions": []}
        """#.utf8))
        XCTAssertNil(profile.userGroup)
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
        for senderID: Int32 in [1, 2] {
            let pending = PendingOutgoingMessage(
                chatID: "chat", clientGeneratedID: "queued-\(senderID)",
                body: .init(messageType: .text, clientGeneratedId: "queued-\(senderID)", message: "Hi"),
                enqueuedAt: TimelineTestFixtures.date(second: 0), senderID: senderID, state: .queued
            )
            let presentation = TimelineRowPresentation.make(
                row: .message(.init(entry: .pending(pending), isOutgoing: true, groupPosition: .single, showsSenderName: true)),
                currentUserProfile: profile, currentUserID: 1, isThreadTimeline: false, environment: environment
            )
            let title = try XCTUnwrap(presentation.title)
            XCTAssertEqual(title.name, senderID == 1 ? "Local name" : "User 2")
            XCTAssertEqual(title.genderGlyph, senderID == 1 ? "♀" : "♂")
            XCTAssertNil(title.groupName)
        }
    }

    func testUnconstrainedHeaderFitsFullNameGroupAndGender() throws {
        // Display rounding must not let the badge and gender borrow the final
        // fraction of a point needed to render the sender's last glyph.
        for (name, gender, captionSize, expectedGlyph) in [("wei", 0, CGFloat(12), "♂"), ("Wei", 1, CGFloat(12), "♂"), ("Wei Zhang", 2, CGFloat(17), "♀")] {
            for scale: CGFloat in [1, 2, 3] {
                let environment = TimelineLayoutEnvironment.current(
                    timelineWidth: 600, displayScale: scale, captionSize: captionSize
                )
                let presentation = try presentation(name: name, gender: gender, environment: environment)
                let title = try XCTUnwrap(presentation.title)
                XCTAssertEqual(title.genderGlyph, expectedGlyph)
                let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
                let frame = try XCTUnwrap(layout.frames[.title])
                let items = layout.titleFrames
                try assertContainedNonoverlappingItems(items, in: frame.size)
                XCTAssertLessThan(frame.width, environment.centralWidth, "This case must have room to display every label.")

                assertFits(title.name, font: .systemFont(ofSize: captionSize, weight: .semibold), in: items[0], scale: scale)
                assertFits(try XCTUnwrap(title.groupName), font: .systemFont(ofSize: captionSize), in: items[1], horizontalPadding: 10, scale: scale)
                assertFits(try XCTUnwrap(title.genderGlyph), font: .systemFont(ofSize: captionSize), in: items[2], scale: scale)
            }
        }
    }

    func testConstrainedHeaderPrioritizesNameOverGroupAndGender() throws {
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 220, displayScale: 2)
        let presentation = try presentation(
            name: "Wei Zhang with a name longer than the available header", gender: 2, environment: environment
        )
        let title = try XCTUnwrap(presentation.title)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        let frame = try XCTUnwrap(layout.frames[.title])
        let items = layout.titleFrames
        try assertContainedNonoverlappingItems(items, in: frame.size)
        XCTAssertLessThanOrEqual(frame.width, environment.centralWidth)
        let nameSize = NSAttributedString(
            string: title.name,
            attributes: [.font: SenderHeaderFont.systemFont(ofSize: environment.captionSize, weight: .semibold)]
        ).size()
        XCTAssertGreaterThan(items[0].width, 0)
        XCTAssertLessThan(items[0].width, nameSize.width, "A constrained header must not force the long username to fit.")
        XCTAssertEqual(items[0].width, frame.width)
        XCTAssertEqual(items[1].width, 0)
        XCTAssertEqual(items[2].width, 0)
    }
    func testGenderFitsBeforeGroupWhenColumnCannotFitAllHeaderItems() throws {
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 180)
        let presentation = try presentation(name: "Wei", gender: 1, environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        let title = try XCTUnwrap(presentation.title)
        assertFits(title.name, font: .systemFont(ofSize: environment.captionSize, weight: .semibold),
                   in: layout.titleFrames[0], scale: environment.displayScale)
        assertFits(try XCTUnwrap(title.genderGlyph), font: .systemFont(ofSize: environment.captionSize),
                   in: layout.titleFrames[2], scale: environment.displayScale)
        XCTAssertEqual(layout.titleFrames[1].width, 0)
    }


    func testHeaderSharesBubbleInsetsAndContributesToBubbleHeight() throws {
        for outgoing in [false, true] {
            for width: CGFloat in [320, 900] {
                let environment = TimelineLayoutEnvironment.current(timelineWidth: width)
                let presentation = try presentation(
                    name: "Wei Zhang with a longer username", gender: 1, outgoing: outgoing, environment: environment
                )
                let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
                let title = try XCTUnwrap(layout.frames[.title])
                let bubble = try XCTUnwrap(layout.frames[.bubble])
                let text = try XCTUnwrap(layout.frames[.text])
                XCTAssertTrue(bubble.contains(title))
                XCTAssertEqual(title.minX, bubble.minX + 12, accuracy: 0.001)
                XCTAssertEqual(title.maxX, bubble.maxX - 12, accuracy: 0.001)
                XCTAssertEqual(title.minY, bubble.minY + 8, accuracy: 0.001)
                XCTAssertEqual(text.minY, title.maxY + 4, accuracy: 0.001)
                XCTAssertEqual(text.minX, title.minX, accuracy: 0.001)
                XCTAssertEqual(bubble.maxY, text.maxY + 8, accuracy: 0.001)
                XCTAssertEqual(layout.size.height, bubble.maxY + 4, accuracy: 0.001)
                XCTAssertLessThanOrEqual(bubble.width, environment.centralWidth)
                XCTAssertEqual(layout.titleFrames[2].maxX, title.width, accuracy: 0.001)
                try assertContainedNonoverlappingItems(layout.titleFrames, in: title.size)
            }
        }
    }

    private func presentation(
        name: String,
        gender: Int,
        outgoing: Bool = false,
        environment: TimelineLayoutEnvironment
    ) throws -> TimelineRowPresentation {
        let senderID: Int32 = outgoing ? 1 : 2
        let message = try TimelineTestFixtures.message(id: "sender-header", senderID: senderID, at: 0, fields: [
            "message": "Hi",
            "sender": [
                "uid": senderID, "name": name, "gender": gender,
                "userGroup": ["groupId": 1, "name": "程序员"]
            ]
        ])
        let row = TimelineRow.message(.init(
            entry: .remote(message), isOutgoing: outgoing, groupPosition: .single, showsSenderName: true
        ))
        return TimelineRowPresentation.make(
            row: row, currentUserProfile: nil, currentUserID: 1, isThreadTimeline: false, environment: environment
        )
    }

    private func assertFits(
        _ text: String,
        font: SenderHeaderFont,
        in frame: CGRect,
        horizontalPadding: CGFloat = 0,
        scale: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let nativeSize = NSAttributedString(string: text, attributes: [.font: font]).size()
        // Only floating-point arithmetic tolerance: a display-pixel tolerance
        // would hide the subpixel shortage that turns "wei" into "w…".
        XCTAssertGreaterThanOrEqual(frame.width + 0.0001, nativeSize.width + horizontalPadding,
                                    "\(text) must fit at display scale \(scale) without truncation or clipping.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height + 0.0001, nativeSize.height,
                                    "\(text) must fit vertically.", file: file, line: line)
    }

    private func assertContainedNonoverlappingItems(
        _ items: [CGRect],
        in size: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(items.count, 3, file: file, line: line)
        guard items.count == 3 else { throw XCTUnwrapFailure.missingHeaderItems }
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.0001, dy: -0.0001)
        for item in items {
            XCTAssertTrue(item.minX.isFinite && item.minY.isFinite && item.width.isFinite && item.height.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(item.width, 0, file: file, line: line)
            XCTAssertGreaterThan(item.height, 0, file: file, line: line)
            XCTAssertTrue(bounds.contains(item), "Every header label must remain inside the assigned title frame.", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(items[0].maxX, items[1].minX, file: file, line: line)
        XCTAssertLessThanOrEqual(items[1].maxX, items[2].minX, file: file, line: line)
    }

    private enum XCTUnwrapFailure: Error {
        case missingHeaderItems
    }
}
