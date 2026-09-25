import SwiftUI
import XCTest

@testable import chahua_apple

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
final class MessageTextLayoutTests: XCTestCase {
    #if os(macOS)
        func testNativeTextPreservesSelectionAndUsesCurrentLinkActions() throws {
            var opened: [String] = []
            let prepared = try preparedText("Hello https://example.com", width: 340)
            func content(_ prefix: String?) -> MessageTextContent {
                MessageTextContent(
                    text: "Hello https://example.com", mentions: [], currentUserID: 1,
                    isOutgoing: false,
                    action: prefix.map { prefix in { opened.append(prefix + $0.absoluteString) } },
                    metadata: prepared.metadata, geometry: prepared.geometry, fontSize: 14
                )
            }
            let text = AppKitMessageTextView(geometry: prepared.geometry)
            text.frame = NSRect(x: 0, y: 0, width: 340, height: 100)
            text.apply(content("first:"), resetSelection: true)
            let link = try XCTUnwrap(text.textStorage?.attribute(.link, at: 6, effectiveRange: nil))
            text.setSelectedRange(NSRange(location: 0, length: 5))
            _ = text.delegate?.textView?(text, clickedOnLink: link, at: 6)
            XCTAssertEqual(opened, ["first:https://example.com"])

            text.apply(content("replacement:"), resetSelection: false)
            XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))
            _ = text.delegate?.textView?(text, clickedOnLink: link, at: 6)
            XCTAssertEqual(
                opened, ["first:https://example.com", "replacement:https://example.com"])

            text.apply(content(nil), resetSelection: false)
            XCTAssertNil(text.textStorage?.attribute(.link, at: 6, effectiveRange: nil))
            _ = text.delegate?.textView?(text, clickedOnLink: link, at: 6)
            XCTAssertEqual(
                opened, ["first:https://example.com", "replacement:https://example.com"])
            XCTAssertEqual(text.string, "Hello https://example.com")
        }

        func testNativeLinkHoverUsesHandWithoutDisablingTextSelection() throws {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let previousCursor = NSCursor.current
            defer {
                window.close()
                previousCursor.set()
            }
            let prepared = try preparedText("Hello https://example.com", width: 136)
            let text = AppKitMessageTextView(geometry: prepared.geometry)
            text.apply(
                MessageTextContent(
                    text: "Hello https://example.com", mentions: [], currentUserID: 1,
                    isOutgoing: false, action: { _ in },
                    metadata: prepared.metadata, geometry: prepared.geometry, fontSize: 14
                ), resetSelection: true)
            window.contentView = text
            text.setSelectedRange(NSRange(location: 0, length: 5))

            func hover(_ characterIndex: Int) throws {
                let layout = text.contentLayout
                let glyphs = layout.layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: characterIndex, length: 1),
                    actualCharacterRange: nil
                )
                let rect = layout.layoutManager.boundingRect(
                    forGlyphRange: glyphs, in: layout.textContainer)
                let point = text.convert(
                    NSPoint(
                        x: rect.midX + text.textContainerOrigin.x,
                        y: rect.midY + text.textContainerOrigin.y),
                    to: nil
                )
                let event = try XCTUnwrap(
                    NSEvent.enterExitEvent(
                        with: .cursorUpdate, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
                    ))
                text.cursorUpdate(with: event)
            }

            try hover(8)
            XCTAssertEqual(NSCursor.current, .pointingHand)
            try hover(1)
            XCTAssertEqual(NSCursor.current, .iBeam)
            try hover(text.string.utf16.count - 1)
            XCTAssertEqual(NSCursor.current, .pointingHand)
            XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))

            text.textStorage?.removeAttribute(
                .link, range: NSRange(location: 0, length: text.string.utf16.count))
            try hover(8)
            XCTAssertEqual(NSCursor.current, .iBeam)
        }
    #else
        func testUIKitSelectionSurvivesActionReplacementAndDisabledLinksCannotEscape() async throws
        {
            var opened: [String] = []
            let prepared = try preparedText("Hello https://example.com @[uid:2]", width: 300)
            func content(_ prefix: String?) -> MessageTextContent {
                MessageTextContent(
                    text: "Hello https://example.com @[uid:2]", mentions: [], currentUserID: 1,
                    isOutgoing: false,
                    action: prefix.map { prefix in { opened.append(prefix + $0.absoluteString) } },
                    mentionAction: prefix.map { prefix in
                        { opened.append(prefix + "mention:\($0)") }
                    },
                    metadata: prepared.metadata, geometry: prepared.geometry, fontSize: 14
                )
            }
            let host = UIViewController()
            let text = UIKitMessageTextView(geometry: prepared.geometry)
            text.apply(content("first:"), resetSelection: true)
            host.view.addSubview(text)
            text.frame = CGRect(origin: .zero, size: prepared.geometry.size)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            func settle() async throws {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutIfNeeded()
            }
            try await settle()
            let linkRange = (text.text as NSString).range(of: "https://example.com")
            let mentionRange = (text.text as NSString).range(of: "@User 2")
            let expectedText = "Hello https://example.com \u{2002}@User 2\u{2002}"
            XCTAssertEqual(
                text.text, expectedText, "Timestamp metadata must not enter the selectable text.")
            let coordinator = try XCTUnwrap(text.delegate as? MessageTextContent.Coordinator)
            text.selectedRange = NSRange(location: 0, length: 5)
            coordinator.activateLink(in: text.textStorage, at: linkRange.location)
            coordinator.activateLink(in: text.textStorage, at: mentionRange.location)
            XCTAssertEqual(opened, ["first:https://example.com", "first:mention:2"])

            text.apply(content("replacement:"), resetSelection: false)
            try await settle()
            XCTAssertEqual(text.selectedRange, NSRange(location: 0, length: 5))
            coordinator.activateLink(in: text.textStorage, at: linkRange.location)
            coordinator.activateLink(in: text.textStorage, at: mentionRange.location)
            let expectedActions = [
                "first:https://example.com", "first:mention:2", "replacement:https://example.com",
                "replacement:mention:2",
            ]
            XCTAssertEqual(opened, expectedActions)

            text.apply(content(nil), resetSelection: false)
            try await settle()
            coordinator.activateLink(in: text.textStorage, at: linkRange.location)
            coordinator.activateLink(in: text.textStorage, at: mentionRange.location)
            XCTAssertEqual(opened, expectedActions)
            XCTAssertEqual(text.selectedRange, NSRange(location: 0, length: 5))
            XCTAssertEqual(text.text, expectedText)
        }
    #endif

    func testShortTextHasCompactIdealWidthWithInlineMetadata() {
        let layout = makeLayout("Hello")
        let size = layout.idealSize
        XCTAssertLessThan(size.width, 180)
        let geometry = layout.geometry(for: size.width)
        XCTAssertTrue(geometry.metadataIsInline)
        XCTAssertGreaterThanOrEqual(geometry.metadataFrame.minX, geometry.lastLineBounds.maxX)
        XCTAssertLessThanOrEqual(geometry.metadataFrame.maxY, geometry.size.height)
    }

    func testMetadataUsesResolvedTextWidth() {
        let layout = makeLayout("Hi")
        let ideal = layout.idealSize
        let assignedWidth = ideal.width + 100
        let geometry = layout.geometry(for: assignedWidth)
        XCTAssertEqual(geometry.metadataFrame.maxX, assignedWidth, accuracy: 0.5)
        XCTAssertTrue(geometry.metadataIsInline)
    }

    func testShortHeaderlessBubbleCentersTextAndTimestampAtAvatarHeight() throws {
        let message = try TimelineTestFixtures.message(
            id: "short-avatar", senderID: 1, at: 1, fields: ["message": "得很多年"])
        let row = TimelineRow.message(
            .init(
                entry: .remote(message), isOutgoing: true, groupPosition: .last,
                showsSenderName: false))
        let environment = TimelineLayoutEnvironment.current(
            timelineWidth: 360, bodySize: 14, avatarSize: 52)
        let presentation = TimelineRowPresentation.make(
            row: row, currentUserProfile: nil, currentUserID: 1,
            isThreadTimeline: false, environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        let bubble = try XCTUnwrap(layout.frames[.bubble])
        let text = try XCTUnwrap(layout.frames[.text])
        let geometry = try XCTUnwrap(layout.textGeometry)
        let visible = geometry.visibleBounds.offsetBy(dx: text.minX, dy: text.minY)
        XCTAssertEqual(bubble.height, environment.avatarSize, accuracy: 0.5)
        XCTAssertEqual(visible.midY, bubble.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(text.minY - bubble.minY, TimelineRowMetrics.textVerticalInset)
        XCTAssertGreaterThanOrEqual(bubble.maxY - text.maxY, TimelineRowMetrics.textVerticalInset)
        let standardEnvironment = TimelineLayoutEnvironment.current(timelineWidth: 360)
        let standardPresentation = TimelineRowPresentation.make(
            row: row, currentUserProfile: nil, currentUserID: 1,
            isThreadTimeline: false, environment: standardEnvironment)
        let standard = TimelineLayoutEngine().layout(
            standardPresentation, environment: standardEnvironment)
        let standardBubble = try XCTUnwrap(standard.frames[.bubble])
        let standardText = try XCTUnwrap(standard.frames[.text])
        let standardInk = try XCTUnwrap(standard.textGeometry).visibleBounds
            .offsetBy(dx: standardText.minX, dy: standardText.minY)
        XCTAssertEqual(standardInk.midY, standardBubble.midY, accuracy: 0.5)

        let tallMessage = try TimelineTestFixtures.message(
            id: "tall-avatar", senderID: 1, at: 2,
            fields: ["message": "One\nTwo\nThree\nFour"])
        let tallRow = TimelineRow.message(
            .init(
                entry: .remote(tallMessage), isOutgoing: true, groupPosition: .last,
                showsSenderName: false))
        let tallPresentation = TimelineRowPresentation.make(
            row: tallRow, currentUserProfile: nil, currentUserID: 1,
            isThreadTimeline: false, environment: environment)
        let tallLayout = TimelineLayoutEngine().layout(
            tallPresentation, environment: environment)
        let tallBubble = try XCTUnwrap(tallLayout.frames[.bubble])
        let tallText = try XCTUnwrap(tallLayout.frames[.text])
        XCTAssertGreaterThan(tallBubble.height, environment.avatarSize)
        XCTAssertEqual(
            tallText.minY - tallBubble.minY, TimelineRowMetrics.textVerticalInset, accuracy: 0.5)
        XCTAssertEqual(
            tallBubble.maxY - tallText.maxY, TimelineRowMetrics.textVerticalInset, accuracy: 0.5)
    }

    func testImageCaptionUsesAvailableLastLineForTimestamp() throws {
        let message = try TimelineTestFixtures.message(
            id: "image-caption", at: 1,
            fields: [
                "message": "Short caption",
                "hasAttachments": true,
                "attachments": [
                    [
                        "id": "image", "url": "https://media.example/image.png",
                        "kind": "image/png", "size": 900, "fileName": "image.png",
                        "width": 240, "height": 150,
                    ]
                ],
            ])
        let row = TimelineRow.message(
            .init(
                entry: .remote(message), isOutgoing: true, groupPosition: .last,
                showsSenderName: false))
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 360)
        let presentation = TimelineRowPresentation.make(
            row: row, currentUserProfile: nil, currentUserID: 1,
            isThreadTimeline: false, environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        let bubble = try XCTUnwrap(layout.frames[.bubble])
        let media = try XCTUnwrap(layout.frames[.media])
        let text = try XCTUnwrap(layout.frames[.text])
        let geometry = try XCTUnwrap(layout.textGeometry)
        XCTAssertTrue(geometry.metadataIsInline)
        XCTAssertNil(layout.frames[.metadata])
        XCTAssertEqual(text.minY, media.maxY + 4, accuracy: 0.5)
        XCTAssertEqual(bubble.maxY - text.maxY, TimelineRowMetrics.textVerticalInset, accuracy: 0.5)
        XCTAssertLessThanOrEqual(geometry.metadataFrame.maxX, text.width)
        XCTAssertLessThanOrEqual(geometry.metadataFrame.maxY, text.height)
    }

    func testMetadataMovesBelowCrowdedFinalLineAndBackAfterResize() {
        let layout = makeLayout("A final line that nearly fills its container")
        let ideal = layout.idealSize
        let narrow = layout.geometry(for: ideal.width - 10)
        XCTAssertFalse(narrow.metadataIsInline)
        XCTAssertGreaterThanOrEqual(narrow.metadataFrame.minY, narrow.bodyBounds.maxY)
        let wide = layout.geometry(for: ideal.width)
        XCTAssertTrue(wide.metadataIsInline)
        XCTAssertLessThan(wide.size.height, narrow.size.height)
        XCTAssertLessThanOrEqual(wide.metadataFrame.maxX, wide.size.width)
    }

    func testSeparateMetadataInkFitsItsAllocatedRowAtFractionalAndDynamicSizes() throws {
        for (fontSize, displayScale) in [(CGFloat(12), CGFloat(2)), (12.5, 1.5), (28, 3)] {
            let metadata = MessageMetadata(
                time: "00:17 (Edited)", state: .failed,
                isOutgoing: true, fontSize: fontSize)
            let layout = MessageTextLayout(
                attributedText: MessageTextContent.attributedText(
                    text: "A crowded final line", mentions: [], currentUserID: 1,
                    isOutgoing: true, font: .systemFont(ofSize: fontSize * 17 / 12)),
                metadata: metadata)
            let geometry = layout.geometry(for: metadata.size.width)
            XCTAssertFalse(geometry.metadataIsInline)
            XCTAssertLessThanOrEqual(geometry.metadataFrame.maxY, geometry.size.height)

            // Leave room outside the allocation: any escaped ink would be clipped
            // when this same drawing is hosted at the native text view's bottom.
            let frame = geometry.metadataFrame.offsetBy(dx: 8.25, dy: 8.25)
            let width = Int(ceil((frame.maxX + 8) * displayScale))
            let height = Int(ceil((frame.maxY + 8) * displayScale))
            let context = try XCTUnwrap(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: displayScale, y: -displayScale)
            #if os(macOS)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                metadata.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
            #else
                UIGraphicsPushContext(context)
                metadata.draw(in: frame)
                UIGraphicsPopContext()
            #endif
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let allocation = CGRect(
                x: frame.minX * displayScale, y: frame.minY * displayScale,
                width: frame.width * displayScale, height: frame.height * displayScale
            ).integral
            var drawnPixels = 0
            var escapedPixels = 0
            for y in 0..<height {
                for x in 0..<width where pixels[y * context.bytesPerRow + x * 4 + 3] > 0 {
                    drawnPixels += 1
                    if !allocation.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                        escapedPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(drawnPixels, 0)
            XCTAssertEqual(
                escapedPixels, 0,
                "Timestamp and delivery ink must fit the measured row at \(fontSize) pt, \(displayScale)x."
            )
        }
    }

    func testStandaloneMetadataKeepsItsDrawingHeightWhenSectionEdgesSnapToPixels() throws {
        let message = try TimelineTestFixtures.message(
            id: "metadata-only", senderID: 2, at: 0,
            hour: 0, minute: 17, fields: ["message": ""])
        let row = TimelineRow.message(
            .init(
                entry: .remote(message), isOutgoing: false,
                groupPosition: .single, showsSenderName: false))
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 320, displayScale: 1.1)
        let presentation = TimelineRowPresentation.make(
            row: row, currentUserProfile: nil, currentUserID: 1,
            isThreadTimeline: false, environment: environment)
        let metadata = try XCTUnwrap(presentation.metadata)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        let frame = try XCTUnwrap(layout.frames[.metadata])
        let drawnHeight = metadata.size.height * min(1, frame.width / metadata.size.width)
        XCTAssertGreaterThanOrEqual(
            frame.height + 0.0001, drawnHeight,
            "Pixel alignment must not shorten the native timestamp drawing surface.")
    }
    #if os(macOS)
        func testMetadataAdoptsDarkAppearanceRatherThanItsCreationAppearance() throws {
            var metadata: MessageMetadata?
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                metadata = MessageMetadata(time: "12:34", state: nil, isOutgoing: false)
            }
            let geometry = MessageTextLayout(
                attributedText: NSAttributedString(string: ""), metadata: metadata
            ).geometry(for: 80)
            let view = AppKitMessageTextView(geometry: geometry)
            view.appearance = NSAppearance(named: .darkAqua)
            view.drawsBackground = true
            view.backgroundColor = .black
            view.contentLayout.update(
                attributedText: NSAttributedString(string: ""), metadata: metadata)
            view.contentLayout.install(geometry: geometry)
            view.frame = CGRect(x: 0, y: 0, width: 80, height: 24)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var brightest: CGFloat = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                        continue
                    }
                    brightest = max(
                        brightest, color.redComponent, color.greenComponent, color.blueComponent)
                }
            }
            XCTAssertGreaterThan(
                brightest, 0.4,
                "Metadata created outside a drawing pass must resolve its color in the displaying view."
            )
        }
    #endif

    private func preparedText(_ text: String, width: CGFloat) throws -> (
        geometry: MessageTextGeometry, metadata: MessageMetadata?
    ) {
        let message = try TimelineTestFixtures.message(
            id: "selectable", senderID: 2, at: 0, hour: 12, minute: 34, fields: ["message": text])
        let row = TimelineRow.message(
            .init(
                entry: .remote(message), isOutgoing: false, groupPosition: .single,
                showsSenderName: false))
        let environment = TimelineLayoutEnvironment.current(
            timelineWidth: width + 24 + 2 * (36 + 8), bodySize: 14,
            timeZone: TimeZone(secondsFromGMT: 0)!)
        let presentation = TimelineRowPresentation.make(
            row: row, currentUserProfile: nil, currentUserID: 1, isThreadTimeline: false,
            environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        return (try XCTUnwrap(layout.textGeometry), presentation.metadata)
    }

    private func makeLayout(_ text: String) -> MessageTextLayout {
        MessageTextLayout(
            attributedText: MessageTextContent.attributedText(
                text: text, mentions: [], currentUserID: 1, isOutgoing: false,
                font: .systemFont(ofSize: 14)
            ),
            metadata: MessageMetadata(time: "12:34", state: nil, isOutgoing: false)
        )
    }
}
