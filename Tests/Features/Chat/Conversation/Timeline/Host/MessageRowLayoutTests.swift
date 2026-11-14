import ChahuaAPI
import SwiftUI
import XCTest

@testable import chahua_apple

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

#if os(macOS)

    @MainActor
    final class MessageRowLayoutTests: XCTestCase {
        func testNativeLinkCardOpensStoredDestinationAndClearsOnReuse() async throws {
            let destination = "https://example.com/article?tag=one#section"
            let description = """
                How we trimmed launch work, lazy-loaded the sidebar \
                and moved sync off the main thread.
                """
            let message = try TimelineTestFixtures.message(
                id: 1, at: 1,
                fields: [
                    "message": "Both worth reading:\n\(destination)",
                    "metadata": [
                        "linkPreviews": [
                            [
                                "url": destination, "status": "ready",
                                "title": "Cutting cold start by 40%", "description": description,
                            ],
                            [
                                "url": "https://fieldnotes.example.org/glass", "status": "ready",
                                "title": "Designing with glass",
                            ],
                            [
                                "url": "https://example.org/pending", "status": "pending",
                                "expiresAt": "2099-01-01T00:00:00Z",
                                "description": description,
                            ],
                        ]
                    ],
                ])
            let environment = TimelineLayoutEnvironment.current(timelineWidth: 420)
            let native = TimelineRowView(frame: .zero)
            var opened: URL?
            var actions = TimelineBubbleActions()
            actions.openLink = { opened = $0 }
            func bind(_ message: MessageResponse, outgoing: Bool) -> TimelineRowLayout {
                let row = TimelineRow.message(
                    .init(
                        entry: .remote(message), isOutgoing: outgoing, groupPosition: .single,
                        showsSenderName: false))
                let presentation = TimelineRowPresentation.make(
                    row: row, currentUserID: 1, isThreadTimeline: false, environment: environment)
                let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
                native.frame = CGRect(origin: .zero, size: layout.size)
                native.bind(
                    .init(
                        presentation: presentation, layout: layout,
                        context: .init(currentUserID: 1),
                        actions: actions, mediaContext: nil))
                return layout
            }
            let layout = bind(message, outgoing: false)
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: layout.size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = native
            window.orderFront(nil)
            native.setVisible(true)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(50))
            native.layoutSubtreeIfNeeded()
            func buttons(in view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
            }
            func messageText(in view: NSView) -> AppKitMessageTextView? {
                if let text = view as? AppKitMessageTextView { return text }
                for child in view.subviews {
                    if let text = messageText(in: child) { return text }
                }
                return nil
            }
            let card = try XCTUnwrap(
                buttons(in: native).first {
                    $0.accessibilityURL()?.absoluteString == destination
                })
            let painted = try XCTUnwrap(
                card.subviews.compactMap { $0 as? LinkPreviewFlowTextView }.first)
            let flow = try XCTUnwrap(painted.flowLayout)
            XCTAssertTrue(flow === layout.linkPreviewLayouts[0])
            XCTAssertEqual(painted.bounds.width, flow.width)
            XCTAssertEqual(card.bounds.height, flow.height + 12)
            let summary = flow.lineFragments(for: .description)
            let headline = flow.lineFragments(for: .title)
            let domain = flow.lineFragments(for: .domain)
            XCTAssertFalse(summary.isEmpty)
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(summary.first).minY, try XCTUnwrap(headline.last).maxY)
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(domain.first).minY, try XCTUnwrap(summary.last).maxY)
            XCTAssertLessThanOrEqual(summary.count, 3)
            XCTAssertTrue(summary.contains { $0.width == flow.width })
            XCTAssertTrue(card.bounds.contains(painted.frame))
            XCTAssertTrue(card.accessibilityLabel()?.contains(description) == true)
            XCTAssertGreaterThanOrEqual(
                layout.linkPreviewFrames[1].height, layout.linkPreviewFrames[2].height)
            // Inspect painted glyphs, not just the allocated multiline rectangle.
            let scale: CGFloat = 2
            let width = Int(ceil(painted.bounds.width * scale))
            let height = Int(ceil(painted.bounds.height * scale))
            let context = try XCTUnwrap(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            context.clip(to: summary.reduce(CGRect.null) { $0.union($1) })
            flow.draw(foregroundColor: .black, secondaryColor: .black)
            NSGraphicsContext.restoreGraphicsState()
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            var paintedLines = 0
            var previousRowHadInk = false
            for y in 0..<height {
                var rowHasInk = false
                for x in 0..<width where pixels[y * context.bytesPerRow + x * 4 + 3] > 32 {
                    rowHasInk = true
                    break
                }
                if rowHasInk && !previousRowHadInk { paintedLines += 1 }
                previousRowHadInk = rowHasInk
            }
            XCTAssertGreaterThan(
                paintedLines, 1, "A multiline description must paint wrapped lines.")
            XCTAssertLessThanOrEqual(
                paintedLines, 3, "Description ink must fit the three-line limit.")
            let bitmap = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
            card.cacheDisplay(in: card.bounds, to: bitmap)
            let attachment = XCTAttachment(
                data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                uniformTypeIdentifier: "public.png")
            attachment.name = "Native link preview with wrapped description"
            attachment.lifetime = .keepAlways
            add(attachment)
            _ = bind(message, outgoing: true)
            native.layoutSubtreeIfNeeded()
            XCTAssertFalse(painted.isHidden)
            let text = try XCTUnwrap(messageText(in: native))
            XCTAssertGreaterThanOrEqual(
                native.convert(card.bounds, from: card).minY,
                native.convert(text.bounds, from: text).maxY)
            let footer = try XCTUnwrap(layout.frames[.metadata])
            XCTAssertGreaterThanOrEqual(
                footer.minY, try XCTUnwrap(layout.linkPreviewFrames.last).maxY)
            XCTAssertTrue(try XCTUnwrap(layout.textGeometry).metadataFrame.isEmpty)
            card.performClick(nil)
            XCTAssertEqual(opened?.absoluteString, destination)
            let describedHeight = card.frame.height
            let compact = try TimelineTestFixtures.message(
                id: 1, at: 1,
                fields: [
                    "message": "Both worth reading:\n\(destination)",
                    "metadata": [
                        "linkPreviews": [
                            ["url": destination, "status": "ready", "title": "How sync works"]
                        ]
                    ],
                ])
            _ = bind(compact, outgoing: false)
            native.layoutSubtreeIfNeeded()
            XCTAssertTrue(
                try XCTUnwrap(painted.flowLayout).lineFragments(for: .description).isEmpty)
            XCTAssertLessThan(card.frame.height, describedHeight)
            let plain = try TimelineTestFixtures.message(id: 2, at: 2, text: "No preview")
            let plainLayout = bind(plain, outgoing: false)
            XCTAssertNil(plainLayout.frames[.metadata])
            XCTAssertFalse(try XCTUnwrap(plainLayout.textGeometry).metadataFrame.isEmpty)
            opened = nil
            card.performClick(nil)
            XCTAssertNil(opened)
            XCTAssertTrue(card.isHidden)
        }

        func testLinkCardsFollowCaptionAndFilterUnavailableStates() throws {
            let description = """
                How we trimmed launch work, lazy-loaded the sidebar \
                and moved sync off the main thread.
                """
            for type in [MessageType.text, .file, .audio] {
                for bodySize: CGFloat in [17, 34] {
                    let message = try TimelineTestFixtures.message(
                        id: 1, at: 1, type: type, text: "Caption https://example.com/a",
                        fields: [
                            "hasAttachments": type != .text,
                            "attachments": type == .text
                                ? []
                                : [
                                    [
                                        "id": "media", "url": "https://media.example/item",
                                        "kind": type == .audio ? "audio/ogg" : "image/png",
                                        "size": 900, "fileName": "item", "width": 400,
                                        "height": 300,
                                    ]
                                ],
                            "metadata": [
                                "linkPreviews": [
                                    ["url": "https://example.com/hidden", "status": "unavailable"],
                                    [
                                        "url": "https://example.com/expired", "status": "pending",
                                        "expiresAt": "2000-01-01T00:00:00Z",
                                    ],
                                    [
                                        "url": "https://example.com/a", "status": "ready",
                                        "title": "A",
                                        "description": description,
                                    ],
                                    [
                                        "url": "https://example.com/b", "status": "ready",
                                        "title": "B",
                                    ],
                                    [
                                        "url": "https://example.com/c", "status": "ready",
                                        "title": "C",
                                        "description": " \n ",
                                    ],
                                    [
                                        "url": "https://example.com/d", "status": "ready",
                                        "title": "D",
                                    ],
                                ]
                            ],
                        ])
                    let row = TimelineRow.message(
                        .init(
                            entry: .remote(message), isOutgoing: true, groupPosition: .single,
                            showsSenderName: false))
                    let environment = TimelineLayoutEnvironment.current(
                        timelineWidth: 360, bodySize: bodySize, captionSize: bodySize * 12 / 17)
                    let presentation = TimelineRowPresentation.make(
                        row: row, currentUserID: 1, isThreadTimeline: false,
                        environment: environment)
                    XCTAssertEqual(
                        presentation.linkPreviews.map(\.url),
                        [
                            "https://example.com/a", "https://example.com/b",
                            "https://example.com/c",
                        ])
                    let layout = TimelineLayoutEngine().layout(
                        presentation, environment: environment)
                    let first = try XCTUnwrap(layout.linkPreviewFrames.first)
                    let last = try XCTUnwrap(layout.linkPreviewFrames.last)
                    let caption = try XCTUnwrap(layout.frames[.text])
                    let bubble = try XCTUnwrap(layout.frames[.bubble])
                    if let media = layout.frames[type == .audio ? .audio : .media] {
                        XCTAssertGreaterThanOrEqual(caption.minY, media.maxY)
                    }
                    XCTAssertGreaterThanOrEqual(first.minY, caption.maxY)
                    for frame in layout.linkPreviewFrames { XCTAssertTrue(bubble.contains(frame)) }
                    XCTAssertLessThanOrEqual(last.maxY, bubble.maxY)
                    let footer = try XCTUnwrap(layout.frames[.metadata])
                    XCTAssertGreaterThanOrEqual(footer.minY, last.maxY)
                    XCTAssertTrue(bubble.contains(footer))
                    XCTAssertTrue(try XCTUnwrap(layout.textGeometry).metadataFrame.isEmpty)
                    XCTAssertGreaterThan(
                        first.height, layout.linkPreviewFrames[1].height)
                    XCTAssertEqual(layout.linkPreviewFrames[1].height, last.height)
                }
            }
        }

        func testVoiceDurationSharesTimestampRowWithoutOverlapAtNarrowAndLargeTextSizes() throws {
            let message = try TimelineTestFixtures.message(
                id: 1, at: 1, type: .audio,
                fields: [
                    "message": NSNull(), "hasAttachments": true,
                    "attachments": [
                        [
                            "id": "voice", "url": "https://media.example/voice.ogg",
                            "kind": "audio/ogg", "size": 900, "fileName": "voice.ogg",
                        ]
                    ],
                ])
            let row = TimelineRow.message(
                .init(
                    entry: .remote(message), isOutgoing: true, groupPosition: .single,
                    showsSenderName: false))
            for (width, body, caption): (CGFloat, CGFloat, CGFloat) in [
                (360, 17, 12), (200, 34, 24),
            ] {
                let environment = TimelineLayoutEnvironment.current(
                    timelineWidth: width, bodySize: body, captionSize: caption,
                    caption2Size: caption)
                let presentation = TimelineRowPresentation.make(
                    row: row, currentUserID: 1, isThreadTimeline: false, environment: environment)
                let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
                let audio = try XCTUnwrap(layout.frames[.audio])
                let timestamp = try XCTUnwrap(layout.frames[.metadata])
                let metrics = presentation.voiceMetrics
                let duration = CGRect(
                    x: audio.minX, y: audio.maxY - metrics.statusHeight,
                    width: metrics.statusWidth(for: audio.width), height: metrics.statusHeight)
                XCTAssertEqual(duration.midY, timestamp.midY, accuracy: 0.5)
                XCTAssertLessThanOrEqual(duration.maxX, timestamp.minX)
                XCTAssertGreaterThan(duration.width, 0)
                XCTAssertGreaterThan(timestamp.width, 0)
                XCTAssertTrue(audio.insetBy(dx: -0.5, dy: -0.5).contains(timestamp))
            }
        }

        func testReactionsStayBelowBubbleAndAvatarOnBothSides() async throws {
            for outgoing in [false, true] {
                let message = try TimelineTestFixtures.message(
                    id: 1, senderID: outgoing ? 1 : 2, at: 0,
                    fields: [
                        "message": "Body with a final line\nFinal visible line",
                        "threadInfo": ["replyCount": 7],
                        "reactions": [
                            [
                                "emoji": "\u{1F44D}", "count": 8,
                                "reactors": (1...5).map { ["uid": $0] },
                            ],
                            ["emoji": "\u{2764}", "count": 3], ["emoji": "\u{1F389}", "count": 2],
                        ],
                    ])
                let row = TimelineRow.message(
                    .init(
                        entry: .remote(message), isOutgoing: outgoing, groupPosition: .single,
                        showsSenderName: true))
                for width: CGFloat in [320, 600] {
                    let environment = TimelineLayoutEnvironment.current(
                        timelineWidth: width,
                        bodySize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                        captionSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                        caption2Size: NSFont.preferredFont(forTextStyle: .caption2).pointSize)
                    let presentation = TimelineRowPresentation.make(
                        row: row, currentUserID: 1, isThreadTimeline: false,
                        environment: environment)
                    let layout = TimelineLayoutEngine().layout(
                        presentation, environment: environment)
                    let bubble = try XCTUnwrap(layout.frames[.bubble])
                    let avatar = try XCTUnwrap(layout.frames[.avatar])
                    let reactions = try XCTUnwrap(layout.frames[.reactions])
                    let thread = try XCTUnwrap(layout.frames[.thread])
                    XCTAssertEqual(avatar.maxY, bubble.maxY, accuracy: 0.5)
                    XCTAssertGreaterThanOrEqual(reactions.minY, max(avatar.maxY, bubble.maxY) + 8)
                    XCTAssertTrue(bubble.contains(thread))
                    XCTAssertEqual(thread.minX, bubble.minX, accuracy: 0.5)
                    XCTAssertEqual(thread.maxX, bubble.maxX, accuracy: 0.5)
                    XCTAssertEqual(thread.maxY, bubble.maxY, accuracy: 0.5)
                    XCTAssertGreaterThanOrEqual(
                        thread.minY, try XCTUnwrap(layout.frames[.text]).maxY)
                    XCTAssertGreaterThanOrEqual(layout.size.height - reactions.maxY, 8)
                    XCTAssertLessThanOrEqual(bubble.width, environment.centralWidth)
                    let host = NSViewController()
                    let nativeRow = TimelineRowView()
                    nativeRow.bind(
                        .init(
                            presentation: presentation, layout: layout,
                            context: .init(currentUserID: 1), actions: .init(), mediaContext: nil))
                    host.view = nativeRow
                    let window = NSWindow(
                        contentRect: CGRect(origin: .zero, size: layout.size),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentViewController = host
                    window.setContentSize(layout.size)
                    host.view.frame = CGRect(origin: .zero, size: layout.size)
                    window.orderFront(nil)
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(50))
                    host.view.layoutSubtreeIfNeeded()
                    let text = try XCTUnwrap(textView(in: host.view))
                    let rendered = text.convert(text.bounds, to: host.view)
                    XCTAssertTrue(host.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rendered))
                    XCTAssertEqual(
                        rendered.width, try XCTUnwrap(layout.frames[.text]).width, accuracy: 0.5)
                    XCTAssertEqual(
                        rendered.height, try XCTUnwrap(layout.frames[.text]).height, accuracy: 0.5)
                    let glyphs = text.contentLayout.layoutManager.usedRect(
                        for: text.contentLayout.textContainer
                    )
                    .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
                    XCTAssertTrue(
                        text.bounds.insetBy(dx: -0.5, dy: -0.5).contains(glyphs),
                        "The last caption glyph must fit its native text frame.")
                }
            }
        }

        func testThreadFooterReservesTheCompleteLabelAndDisappearsInThreadTimeline() throws {
            let message = try TimelineTestFixtures.message(
                id: 1, senderID: 2, at: 0,
                fields: ["message": "Hi", "threadInfo": ["replyCount": 14]])
            for outgoing in [false, true] {
                let row = TimelineRow.message(
                    .init(
                        entry: .remote(message), isOutgoing: outgoing,
                        groupPosition: .single, showsSenderName: false))
                for fontSize: CGFloat in [13, 26] {
                    let environment = TimelineLayoutEnvironment.current(
                        timelineWidth: 600, bodySize: fontSize)
                    let presentation = TimelineRowPresentation.make(
                        row: row, currentUserID: 1, isThreadTimeline: false,
                        environment: environment)
                    let layout = TimelineLayoutEngine().layout(
                        presentation, environment: environment)
                    let footer = try XCTUnwrap(layout.frames[.thread])
                    let items = layout.threadContentFrames
                    XCTAssertEqual(items.count, 3)
                    let label = try XCTUnwrap(presentation.threadLabel)
                    let measured = NSAttributedString(
                        string: label, attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
                    ).size()
                    XCTAssertGreaterThanOrEqual(items[1].width + 0.5, measured.width)
                    XCTAssertGreaterThanOrEqual(items[1].height + 0.5, measured.height)
                    for item in items {
                        XCTAssertTrue(
                            CGRect(origin: .zero, size: footer.size).insetBy(dx: -0.5, dy: -0.5)
                                .contains(item))
                    }
                    XCTAssertLessThanOrEqual(items[0].maxX, items[1].minX)
                    XCTAssertLessThanOrEqual(items[1].maxX, items[2].minX)

                    let threadPresentation = TimelineRowPresentation.make(
                        row: row, currentUserID: 1, isThreadTimeline: true, environment: environment
                    )
                    let threadLayout = TimelineLayoutEngine().layout(
                        threadPresentation, environment: environment)
                    XCTAssertNil(threadLayout.frames[.thread])
                }
            }
        }

        func testThreadFooterUsesCurrentMessageAndIsReadOnlyInPreview() throws {
            var opened: [MessageID] = []
            func binding(id: UInt64, preview: Bool = false, hasThread: Bool = true) throws
                -> TimelineRowBinding
            {
                var fields: [String: Any] = ["message": "Thread root"]
                if hasThread { fields["threadInfo"] = ["replyCount": 14] }
                let message = try TimelineTestFixtures.message(
                    id: id, senderID: 2, at: 0, fields: fields)
                let row = TimelineRow.message(
                    .init(
                        entry: .remote(message), isOutgoing: false, groupPosition: .single,
                        showsSenderName: false))
                let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
                let presentation = TimelineRowPresentation.make(
                    row: row, currentUserID: 1, isThreadTimeline: false, environment: environment)
                var actions = TimelineBubbleActions()
                actions.openThread = { opened.append($0) }
                return .init(
                    presentation: presentation,
                    layout: TimelineLayoutEngine().layout(presentation, environment: environment),
                    context: .init(currentUserID: 1, isInteractionPreview: preview),
                    actions: actions, mediaContext: nil)
            }
            func buttons(in view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
            }
            let first = try binding(id: 1)
            let native = TimelineBubbleContentView(
                frame: CGRect(origin: .zero, size: try XCTUnwrap(first.layout.frames[.bubble]).size)
            )
            native.bind(first)
            native.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(
                buttons(in: native).first {
                    $0.accessibilityLabel() == first.presentation.threadLabel
                })
            button.performClick(nil)
            native.bind(try binding(id: 2))
            button.performClick(nil)
            XCTAssertEqual(opened, [MessageID(1), MessageID(2)])
            native.bind(try binding(id: 3, preview: true))
            XCTAssertFalse(button.isHidden)
            button.performClick(nil)
            native.bind(try binding(id: 4, hasThread: false))
            button.performClick(nil)
            XCTAssertEqual(opened, [MessageID(1), MessageID(2)])
        }

        func testReusedRowPreservesSameMessageSelectionButResetsForAnotherMessage() async throws {
            var opened: [UInt64] = []
            func binding(id: UInt64, width: CGFloat) throws -> TimelineRowBinding {
                let message = try TimelineTestFixtures.message(
                    id: id, senderID: 2, at: 0, text: "Hello https://example.com")
                let row = TimelineRow.message(
                    .init(
                        entry: .remote(message), isOutgoing: false, groupPosition: .single,
                        showsSenderName: true))
                let environment = TimelineLayoutEnvironment.current(timelineWidth: width)
                let presentation = TimelineRowPresentation.make(
                    row: row, currentUserID: 1, isThreadTimeline: false, environment: environment)
                var actions = TimelineBubbleActions()
                actions.openLink = { _ in opened.append(id) }
                return .init(
                    presentation: presentation,
                    layout: TimelineLayoutEngine().layout(presentation, environment: environment),
                    context: .init(currentUserID: 1), actions: actions, mediaContext: nil)
            }
            let first = try binding(id: 1, width: 600)
            let cell = TimelineTableCellView(frame: CGRect(origin: .zero, size: first.layout.size))
            let window = NSWindow(
                contentRect: cell.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = cell
            window.orderFront(nil)
            defer { window.close() }
            cell.bind(first)
            try await Task.sleep(for: .milliseconds(50))
            cell.layoutSubtreeIfNeeded()
            let initialText = try XCTUnwrap(textView(in: cell))
            initialText.setSelectedRange(NSRange(location: 0, length: 5))

            let resized = try binding(id: 1, width: 400)
            window.setContentSize(resized.layout.size)
            cell.bind(resized)
            try await Task.sleep(for: .milliseconds(50))
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                try XCTUnwrap(textView(in: cell)).selectedRange(), NSRange(location: 0, length: 5))

            cell.bind(try binding(id: 2, width: 400))
            try await Task.sleep(for: .milliseconds(50))
            cell.layoutSubtreeIfNeeded()
            let reusedText = try XCTUnwrap(textView(in: cell))
            XCTAssertEqual(reusedText.string, "Hello https://example.com")
            XCTAssertEqual(
                reusedText.selectedRange().length, 0,
                "Selection must not transfer to another message with identical text.")
            _ = reusedText.delegate?.textView?(
                reusedText, clickedOnLink: URL(string: "https://example.com")!, at: 6)
            XCTAssertEqual(
                opened, [2], "Reused content must dispatch the current message's action.")
        }

        func testReusingReplyableRowForDeletedSystemMessageRemovesHoverAction() throws {
            let nativeRow = TimelineRowView()
            let window = HoverPointerWindow(
                contentRect: CGRect(x: 0, y: 0, width: 600, height: 150),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = nativeRow
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            var replies: [MessageID] = []
            var actions = TimelineBubbleActions()
            actions.replyToMessage = { replies.append($0.id) }
            actions.interactionContext = .init(canWrite: true, speakingMode: .unrestricted)
            let entered = try XCTUnwrap(
                NSEvent.enterExitEvent(
                    with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: 0, userData: nil))
            for system in [false, true] {
                let message = try TimelineTestFixtures.message(
                    id: system ? 2 : 1, at: 0,
                    fields: ["messageType": system ? "system" : "text", "isDeleted": system])
                let row = TimelineRow.message(
                    .init(
                        entry: .remote(message), isOutgoing: false,
                        groupPosition: .single, showsSenderName: true))
                let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
                let presentation = TimelineRowPresentation.make(
                    row: row, currentUserID: 1, isThreadTimeline: false, environment: environment)
                nativeRow.bind(
                    .init(
                        presentation: presentation,
                        layout: TimelineLayoutEngine().layout(
                            presentation, environment: environment),
                        context: .init(currentUserID: 1), actions: actions, mediaContext: nil))
                nativeRow.setVisible(true)
                nativeRow.mouseEntered(with: entered)
                nativeRow.layoutSubtreeIfNeeded()
                let buttons = nativeRow.subviews.compactMap { $0 as? NSButton }.filter {
                    !$0.isHidden
                }
                if system {
                    XCTAssertTrue(
                        buttons.isEmpty,
                        "System rows must not expose a zero-sized reply action after reuse.")
                } else {
                    try XCTUnwrap(buttons.first).performClick(nil)
                    XCTAssertEqual(replies, [MessageID(1)])
                }
            }
        }

        func testScrollingUnderStationaryPointerTransfersReplyHoverWithoutExitEvent() throws {
            let window = HoverPointerWindow(
                contentRect: CGRect(x: 0, y: 0, width: 600, height: 200),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
            let document = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
            scroll.documentView = document
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            var actions = TimelineBubbleActions()
            actions.replyToMessage = { _ in }
            actions.interactionContext = .init(canWrite: true, speakingMode: .unrestricted)
            let environment = TimelineLayoutEnvironment.current(timelineWidth: 600)
            let rows = try (0..<2).map { index -> TimelineRowView in
                let message = try TimelineTestFixtures.message(id: UInt64(index + 1), at: index)
                let row = TimelineRow.message(
                    .init(
                        entry: .remote(message), isOutgoing: false,
                        groupPosition: .single, showsSenderName: true))
                let presentation = TimelineRowPresentation.make(
                    row: row, currentUserID: 1, isThreadTimeline: false, environment: environment)
                let view = TimelineRowView(
                    frame: CGRect(x: 0, y: index * 100, width: 600, height: 100))
                document.addSubview(view)
                view.bind(
                    .init(
                        presentation: presentation,
                        layout: TimelineLayoutEngine().layout(
                            presentation, environment: environment),
                        context: .init(), actions: actions, mediaContext: nil))
                return view
            }
            let entered = try XCTUnwrap(
                NSEvent.enterExitEvent(
                    with: .mouseEntered, location: window.pointer, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: 0, userData: nil))
            func showsReply(_ row: TimelineRowView) -> Bool {
                row.subviews.contains { $0 is NSButton && !$0.isHidden }
            }
            scroll.contentView.scroll(to: .zero)
            for row in rows { row.setVisible(true) }
            rows[0].mouseEntered(with: entered)
            XCTAssertEqual(rows.map(showsReply), [true, false])

            scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
            // Both rows remain visible; neither reuse nor a mouseExited event clears
            // the old row. This is the viewport refresh used by the native table.
            XCTAssertTrue(rows.allSatisfy { !$0.visibleRect.isEmpty })
            for row in rows { row.setVisible(true) }
            XCTAssertEqual(rows.map(showsReply), [false, true])
            rows[0].mouseEntered(with: entered)
            XCTAssertEqual(
                rows.map(showsReply), [false, true],
                "A delayed enter event must not resurrect the old row's hover.")

            scroll.contentView.scroll(to: .zero)
            for row in rows { row.setVisible(true) }
            XCTAssertEqual(rows.map(showsReply), [true, false])
            window.active = false
            for row in rows { row.setVisible(true) }
            XCTAssertEqual(rows.map(showsReply), [false, false])
        }

        private func textView(in view: NSView) -> AppKitMessageTextView? {
            if let text = view as? AppKitMessageTextView { return text }
            return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
        }
    }
    private final class HoverPointerWindow: NSWindow {
        let pointer = NSPoint(x: 50, y: 50)
        var active = true
        override var isKeyWindow: Bool { active }
        override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    }

#endif

@MainActor
final class NativeLinkPreviewFlowTests: XCTestCase {
    func testTextKitReclaimsThumbnailColumnAndKeepsCompleteDomain() throws {
        for rtl in [false, true] {
            for scale: CGFloat in [1, 2] {
                let flow = LinkPreviewFlowLayout(
                    title: "Article",
                    description: String(
                        repeating:
                            "A description wraps beside the tile and then uses the full card. ",
                        count: 8),
                    domain: String(repeating: "long-subdomain.", count: 8) + "example.com",
                    width: 220 * scale,
                    titleFont: .systemFont(ofSize: 14 * scale, weight: .semibold),
                    descriptionFont: .systemFont(ofSize: 13 * scale),
                    domainFont: .systemFont(ofSize: 12 * scale),
                    thumbnailSize: 36 * scale, gap: 8 * scale, rightToLeft: rtl,
                    sectionSpacing: 2 * scale)
                let summary = flow.lineFragments(for: .description)
                XCTAssertEqual(summary.count, 3)
                let beside = summary.filter { $0.minY < flow.thumbnailFrame.maxY }
                let below = summary.filter { $0.minY >= flow.thumbnailFrame.maxY }
                XCTAssertFalse(beside.isEmpty)
                XCTAssertFalse(below.isEmpty)
                for fragment in beside {
                    if rtl {
                        XCTAssertLessThanOrEqual(
                            fragment.maxX, flow.thumbnailFrame.minX - 8 * scale)
                    } else {
                        XCTAssertGreaterThanOrEqual(
                            fragment.minX, flow.thumbnailFrame.maxX + 8 * scale)
                    }
                    XCTAssertLessThan(fragment.width, flow.width)
                }
                for fragment in below {
                    XCTAssertEqual(fragment.minX, 0, accuracy: 0.01)
                    XCTAssertEqual(fragment.width, flow.width, accuracy: 0.01)
                }
                let domain = flow.lineFragments(for: .domain)
                XCTAssertGreaterThan(
                    domain.count, 1, "The domain must wrap, not silently truncate.")
                XCTAssertGreaterThanOrEqual(
                    try XCTUnwrap(domain.first).minY, try XCTUnwrap(summary.last).maxY)
                XCTAssertGreaterThanOrEqual(flow.height, try XCTUnwrap(domain.last).maxY)
                XCTAssertLessThan(flow.height - (try XCTUnwrap(domain.last).maxY), 1)
            }
        }
    }

    func testCachedNativeFlowMatchesRowGeometryAndInvalidatesWithDescription() throws {
        let cache = TimelineLayoutCache()
        func presentation(_ description: String, environment: TimelineLayoutEnvironment) throws
            -> TimelineRowPresentation
        {
            let message = try TimelineTestFixtures.message(
                id: 1, at: 1, text: "Read https://example.com/article",
                fields: [
                    "metadata": [
                        "linkPreviews": [
                            [
                                "url": "https://example.com/article", "status": "ready",
                                "title": "Article", "description": description,
                            ]
                        ]
                    ]
                ])
            return TimelineRowPresentation.make(
                row: .message(
                    .init(
                        entry: .remote(message), isOutgoing: false, groupPosition: .single,
                        showsSenderName: false)),
                currentUserID: 1, isThreadTimeline: false, environment: environment)
        }
        for width: CGFloat in [321.25, 420] {
            let environment = TimelineLayoutEnvironment.current(timelineWidth: width)
            let content = try presentation(
                String(
                    repeating: "The description reclaims the full width below the tile. ", count: 4),
                environment: environment)
            let layout = cache.layout(for: content, environment: environment)
            let flow = try XCTUnwrap(layout.linkPreviewLayouts.first.flatMap { $0 })
            let frame = try XCTUnwrap(layout.linkPreviewFrames.first)
            XCTAssertEqual(frame.width, flow.width + 20)
            XCTAssertEqual(frame.height, flow.height + 12)
            let cached = cache.layout(for: content, environment: environment)
            XCTAssertTrue(flow === cached.linkPreviewLayouts[0])
            let changed = try presentation("Short", environment: environment)
            let revised = cache.layout(for: changed, environment: environment)
            XCTAssertFalse(flow === revised.linkPreviewLayouts[0])
            XCTAssertLessThan(try XCTUnwrap(revised.linkPreviewFrames.first).height, frame.height)
        }
    }

    #if os(iOS)
        func testNativeIOSFlowDrawsCachedGeometryAndCapturesRecoveredWidth() throws {
            let description = String(
                repeating: "Description wraps beside the tile and continues across the full card. ",
                count: 3)
            let message = try TimelineTestFixtures.message(
                id: 1, at: 1, text: "Worth reading https://example.com/article",
                fields: [
                    "metadata": [
                        "linkPreviews": [
                            [
                                "url": "https://example.com/article", "status": "ready",
                                "title": "Article", "description": description,
                            ]
                        ]
                    ]
                ])
            let environment = TimelineLayoutEnvironment.current(timelineWidth: 420)
            let presentation = TimelineRowPresentation.make(
                row: .message(
                    .init(
                        entry: .remote(message), isOutgoing: false, groupPosition: .single,
                        showsSenderName: false)),
                currentUserID: 1, isThreadTimeline: false, environment: environment)
            let layout = TimelineLayoutCache().layout(for: presentation, environment: environment)
            let native = TimelineRowView(frame: CGRect(origin: .zero, size: layout.size))
            native.bind(
                .init(
                    presentation: presentation, layout: layout,
                    context: .init(currentUserID: 1), actions: .init(), mediaContext: nil))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            window.rootViewController = controller
            controller.view.addSubview(native)
            window.makeKeyAndVisible()
            defer {
                native.setVisible(false)
                window.isHidden = true
                previousKeyWindow?.makeKey()
            }
            native.setVisible(true)
            controller.view.layoutIfNeeded()
            native.layoutIfNeeded()
            func textSurface(in view: UIView) -> LinkPreviewFlowTextView? {
                if let text = view as? LinkPreviewFlowTextView { return text }
                return view.subviews.lazy.compactMap { textSurface(in: $0) }.first
            }
            let text = try XCTUnwrap(textSurface(in: native))
            let flow = try XCTUnwrap(text.flowLayout)
            XCTAssertTrue(flow === layout.linkPreviewLayouts[0])
            XCTAssertEqual(text.bounds.width, flow.width)
            XCTAssertEqual(text.bounds.height, flow.height)
            XCTAssertEqual(try XCTUnwrap(text.superview).bounds.height, flow.height + 12)
            XCTAssertTrue(flow.lineFragments(for: .description).contains { $0.minX == 0 })
            let attachment = XCTAttachment(
                image: UIGraphicsImageRenderer(bounds: native.bounds).image { _ in
                    native.drawHierarchy(in: native.bounds, afterScreenUpdates: true)
                })
            attachment.name = "Native iOS timeline link preview — recovered thumbnail column"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    #endif
}
