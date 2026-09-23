#if os(macOS)
    import AppKit
    import SwiftUI
    import XCTest
    @testable import chahua_apple

    @MainActor
    final class ReplyQuoteLayoutTests: XCTestCase {

        func testCachedQuoteHeightMatchesSingleLineBannerForLongAndMultilineOriginals() throws {
            let longLine = String(
                repeating: "Quoted words that must truncate at the bubble edge. ", count: 20)
            for width: CGFloat in [320, 900] {
                let environment = environment(width: width)
                let singleLine = try presentation(
                    author: "Quoted author", quotedText: longLine, environment: environment)
                let multiline = try presentation(
                    author: "Quoted author\nAdditional author line",
                    quotedText: longLine + "\n"
                        + String(repeating: "Additional quoted line\n", count: 12),
                    environment: environment)
                let engine = TimelineLayoutEngine()
                let singleLayout = engine.layout(singleLine, environment: environment)
                let singleQuote = try XCTUnwrap(singleLayout.frames[.reply])
                XCTAssertEqual(
                    try XCTUnwrap(singleLayout.frames[.bubble]).width, environment.centralWidth)
                let multilineQuote = try XCTUnwrap(
                    engine.layout(multiline, environment: environment).frames[.reply])
                let singleRenderedHeight = try bannerHeight(
                    presentation: singleLine, width: singleQuote.width)
                let multilineRenderedHeight = try bannerHeight(
                    presentation: multiline, width: multilineQuote.width)
                let pixel = 1 / environment.displayScale

                XCTAssertEqual(
                    multilineRenderedHeight, singleRenderedHeight, accuracy: pixel,
                    "The real reply banner must truncate each label instead of growing for hidden lines."
                )
                XCTAssertEqual(
                    multilineQuote.height, singleQuote.height, accuracy: pixel,
                    "Changing only truncated quote content must not enlarge the containing bubble.")
                // Each of the two native line heights can round up by one display pixel.
                XCTAssertEqual(singleQuote.height, singleRenderedHeight, accuracy: 2 * pixel)
                XCTAssertEqual(
                    multilineQuote.height, multilineRenderedHeight, accuracy: 2 * pixel,
                    "Cached geometry must fit the actual leaf, not the untruncated original message."
                )
            }
        }

        func testReplyBubbleUsesCompactInsetsWithoutAdditionalRowWhitespace() throws {
            for outgoing in [false, true] {
                let environment = environment(width: 600)
                let presentation = try presentation(
                    author: "Quoted author\nHidden author line",
                    quotedText: String(repeating: "Long original message\n", count: 12),
                    outgoing: outgoing, environment: environment)
                let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
                let bubble = try XCTUnwrap(layout.frames[.bubble])
                let quote = try XCTUnwrap(layout.frames[.reply])
                let body = try XCTUnwrap(layout.frames[.text])
                let avatar = try XCTUnwrap(layout.frames[.avatar])
                let renderedQuoteHeight = try bannerHeight(
                    presentation: presentation, width: quote.width)
                let pixel = 1 / environment.displayScale

                XCTAssertEqual(bubble.minY, 4, accuracy: pixel)
                XCTAssertEqual(quote.minY - bubble.minY, 8, accuracy: pixel)
                XCTAssertEqual(body.minY - quote.maxY, 6, accuracy: pixel)
                XCTAssertEqual(bubble.maxY - body.maxY, 8, accuracy: pixel)
                XCTAssertEqual(
                    bubble.height, 8 + renderedQuoteHeight + 6 + body.height + 8,
                    accuracy: 2 * pixel,
                    "A reply bubble consists only of its two-line quote, body (including metadata), and specified insets."
                )
                XCTAssertEqual(avatar.maxY, bubble.maxY, accuracy: pixel)
                XCTAssertEqual(layout.size.height - bubble.maxY, 4, accuracy: pixel)
            }
        }

        func testHeaderAndQuoteShareOneTopInsetInsideBubble() throws {
            let environment = environment(width: 320)
            let presentation = try presentation(
                author: "Quoted author", quotedText: "Quoted line\nHidden line",
                showsSenderName: true, environment: environment)
            let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
            let bubble = try XCTUnwrap(layout.frames[.bubble])
            let title = try XCTUnwrap(layout.frames[.title])
            let quote = try XCTUnwrap(layout.frames[.reply])
            let body = try XCTUnwrap(layout.frames[.text])
            XCTAssertTrue(bubble.contains(title))
            XCTAssertTrue(bubble.contains(quote))
            XCTAssertEqual(title.minY - bubble.minY, 8, accuracy: 0.5)
            XCTAssertEqual(quote.minY - title.maxY, 4, accuracy: 0.5)
            XCTAssertEqual(body.minY - quote.maxY, 6, accuracy: 0.5)
            XCTAssertEqual(bubble.maxY - body.maxY, 8, accuracy: 0.5)
            XCTAssertEqual(quote.minX, title.minX, accuracy: 0.5)
            XCTAssertEqual(quote.maxX, title.maxX, accuracy: 0.5)
        }

        func testQuoteExpandsShortReplyToFitEitherAuthorOrPreview() throws {
            let environment = environment(width: 900)
            for (author, preview) in [
                ("codetector", "所以我还得\n\ndebug 一下这个问题"),
                ("A quoted author with a substantially longer display name", "Hi"),
            ] {
                let presentation = try presentation(
                    author: author, quotedText: preview, environment: environment)
                let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
                let bubble = try XCTUnwrap(layout.frames[.bubble])
                XCTAssertLessThan(bubble.width, environment.centralWidth)
                _ = try bannerHeight(
                    presentation: presentation, width: try XCTUnwrap(layout.frames[.reply]).width,
                    fitsFullContent: true)
            }
        }

        func testLongQuoteWidensStickerBubbleWithoutEnlargingSticker() throws {
            let environment = environment(width: 900)
            let presentation = try presentation(
                author: "Quoted author",
                quotedText: "A quoted message long enough to need more width than the sticker",
                outgoing: true, messageType: "sticker", environment: environment)
            let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
            let bubble = try XCTUnwrap(layout.frames[.bubble])
            let sticker = try XCTUnwrap(layout.frames[.media])
            XCTAssertGreaterThan(bubble.width, 200)
            XCTAssertEqual(sticker.width, 200)
            XCTAssertEqual(sticker.maxX, bubble.maxX)
            _ = try bannerHeight(
                presentation: presentation, width: try XCTUnwrap(layout.frames[.reply]).width,
                fitsFullContent: true)
        }

        private func environment(width: CGFloat, captionSize: CGFloat? = nil)
            -> TimelineLayoutEnvironment
        {
            .current(
                timelineWidth: width, displayScale: 2,
                bodySize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                captionSize: captionSize ?? NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                caption2Size: NSFont.preferredFont(forTextStyle: .caption2).pointSize)
        }

        private func presentation(
            author: String, quotedText: String, outgoing: Bool = false,
            showsSenderName: Bool = false,
            messageType: String = "text", environment: TimelineLayoutEnvironment
        ) throws -> TimelineRowPresentation {
            let message = try TimelineTestFixtures.message(
                id: "reply-layout", senderID: outgoing ? 1 : 2, at: 0, text: "Reply body",
                fields: [
                    "messageType": messageType,
                    "replyToMessage": [
                        "id": "quoted-message", "clientGeneratedId": "quoted-client",
                        "createdAt": "2026-09-01T00:00:00Z",
                        "sender": ["uid": 3, "gender": 0, "name": author],
                        "messageType": "text", "message": quotedText,
                        "attachments": [], "mentions": [], "isDeleted": false,
                    ],
                ])
            let row = TimelineRow.message(
                .init(
                    entry: .remote(message), isOutgoing: outgoing, groupPosition: .single,
                    showsSenderName: showsSenderName))
            return TimelineRowPresentation.make(
                row: row, currentUserProfile: nil, currentUserID: 1, isThreadTimeline: false,
                environment: environment)
        }

        private func bannerHeight(
            presentation: TimelineRowPresentation, width: CGFloat, fitsFullContent: Bool = false
        ) throws -> CGFloat {
            let layout = TimelineLayoutEngine().layout(
                presentation, environment: presentation.environment)
            let native = TimelineBubbleContentView(
                frame: CGRect(origin: .zero, size: try XCTUnwrap(layout.frames[.bubble]).size))
            native.bind(
                .init(
                    presentation: presentation, layout: layout, context: .init(), actions: .init(),
                    mediaContext: nil))
            native.layoutSubtreeIfNeeded()
            func labels(in view: NSView) -> [NSTextField] {
                if let button = view as? NSButton {
                    let labels = button.subviews.compactMap { $0 as? NSTextField }
                    if labels.count == 2 { return labels }
                }
                return view.subviews.flatMap { labels(in: $0) }
            }
            let renderedLabels = labels(in: native)
            XCTAssertEqual(renderedLabels.count, 2)
            return try renderedLabels.reduce(CGFloat(10)) { result, label in
                let font = try XCTUnwrap(label.font)
                if fitsFullContent {
                    let naturalWidth = NSAttributedString(
                        string: label.stringValue, attributes: [.font: font]
                    ).size().width
                    XCTAssertGreaterThanOrEqual(
                        label.bounds.width, naturalWidth,
                        "A quote must widen a short reply rather than truncate before the column limit."
                    )
                }
                let height = NSAttributedString(
                    string: label.stringValue, attributes: [.font: font]
                )
                .boundingRect(
                    with: CGSize(
                        width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesFontLeading]
                ).height
                XCTAssertGreaterThanOrEqual(
                    label.bounds.height, height - 0.5,
                    "The native quote must not clip its single visible line.")
                return result + height
            }
        }
    }
#endif
