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
final class MessageTextLayoutTests: XCTestCase {
    func testMentionPaddingDoesNotLeaveAnEmptyPillAtLineWrap() throws {
        let mentions = try JSONDecoder().decode(
            [MentionInfo].self, from: Data(#"[{"uid":2,"username":"崩溃","gender":0}]"#.utf8))
        let text = MessageTextContent.attributedText(
            text: "Native preview with @[uid:2] text", mentions: mentions,
            currentUserID: 1, isOutgoing: false, font: .systemFont(ofSize: 17))
        let nameRange = try XCTUnwrap(text.string.range(of: "@崩溃"))
        let name = NSRange(nameRange, in: text.string)
        var mention = NSRange()
        _ = text.attribute(.bubbleMentionID, at: name.location, effectiveRange: &mention)
        let layout = MessageTextLayout(attributedText: text)
        for width in 90...300 {
            _ = layout.geometry(for: CGFloat(width))
            let paddingGlyph = layout.layoutManager.glyphIndexForCharacter(at: mention.location)
            let nameGlyph = layout.layoutManager.glyphIndexForCharacter(at: name.location)
            let paddingLine = layout.layoutManager.lineFragmentRect(
                forGlyphAt: paddingGlyph, effectiveRange: nil)
            let nameLine = layout.layoutManager.lineFragmentRect(
                forGlyphAt: nameGlyph, effectiveRange: nil)
            XCTAssertEqual(
                paddingLine.minY, nameLine.minY,
                "Mention background must not orphan a padding-only fragment at width \(width)")
        }
    }

    func testNativeDeliveryAnimationStopsOffscreenAndOnReuse() throws {
        let view = TimelineDeliveryStatusView(frame: CGRect(x: 0, y: 0, width: 24, height: 20))
        #if os(macOS)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 24, height: 20),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            let layer = try XCTUnwrap(view.layer)
        #else
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            controller.view.addSubview(view)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                previousKeyWindow?.makeKey()
            }
            let layer = view.layer
        #endif
        func animates(_ layer: CALayer) -> Bool {
            !(layer.animationKeys() ?? []).isEmpty
                || (layer.sublayers ?? []).contains(where: animates)
        }
        view.configure(MessageMetadata(time: "12:34", state: .sending, isOutgoing: true))
        #if os(macOS)
            view.layoutSubtreeIfNeeded()
        #else
            view.layoutIfNeeded()
        #endif
        XCTAssertTrue(animates(layer), "Visible sending indicators must animate.")
        view.setVisible(false)
        XCTAssertFalse(animates(layer), "Offscreen rows must not retain a repeating animation.")
        view.setVisible(true)
        XCTAssertTrue(animates(layer))
        view.configure(MessageMetadata(time: "12:34", state: .delivered, isOutgoing: true))
        XCTAssertFalse(
            animates(layer), "Reusing a sending row for a sent message must stop animation.")
        view.configure(nil)
        XCTAssertFalse(animates(layer))
    }

    func testSeparateFooterDoesNotRetainFailedInlineWidth() throws {
        for text in ["现在基本内部都有大规模的 AI 扫 bug", "The timestamp needs its own row"] {
            for bodySize in [CGFloat(17), CGFloat(28)] {
                for outgoing in [false, true] {
                    let message = try TimelineTestFixtures.message(
                        id: 1, senderID: outgoing ? 1 : 2, at: 1, text: text)
                    let row = TimelineRow.message(
                        .init(
                            entry: .remote(message), isOutgoing: outgoing,
                            groupPosition: .last, showsSenderName: false))
                    let wideEnvironment = TimelineLayoutEnvironment.current(
                        timelineWidth: 2_000, bodySize: bodySize,
                        caption2Size: bodySize * 11 / 17)
                    let presentation = TimelineRowPresentation.make(
                        row: row, currentUserID: 1, isThreadTimeline: false,
                        environment: wideEnvironment)
                    let metadata = try XCTUnwrap(presentation.metadata)
                    let measurement = MessageTextLayout(
                        attributedText: MessageTextContent.attributedText(
                            text: text, mentions: [], currentUserID: 1, isOutgoing: outgoing,
                            font: .systemFont(ofSize: bodySize)), metadata: metadata)
                    let natural = measurement.geometry(for: 2_000)
                    let centralWidth = natural.bodyBounds.width + 24 + metadata.size.width / 2
                    let environment = TimelineLayoutEnvironment.current(
                        timelineWidth: centralWidth + 2 * TimelineRowMetrics.rowHorizontalInset
                            + 2 * (wideEnvironment.avatarSize + TimelineRowMetrics.laneGap),
                        bodySize: bodySize, caption2Size: bodySize * 11 / 17)
                    let engine = TimelineLayoutEngine()
                    let layout = engine.layout(presentation, environment: environment)
                    let bubble = try XCTUnwrap(layout.frames[.bubble])
                    let geometry = try XCTUnwrap(layout.textGeometry)
                    XCTAssertFalse(geometry.metadataIsInline)
                    XCTAssertEqual(
                        geometry.bodyBounds.height, natural.bodyBounds.height, accuracy: 0.5)
                    XCTAssertEqual(
                        bubble.width, max(geometry.bodyBounds.width, metadata.size.width) + 24,
                        accuracy: 1 / environment.displayScale)
                    XCTAssertGreaterThanOrEqual(
                        geometry.metadataFrame.minY, geometry.bodyBounds.maxY)
                    let wide = engine.layout(presentation, environment: wideEnvironment)
                    XCTAssertTrue(try XCTUnwrap(wide.textGeometry).metadataIsInline)
                }
            }
        }
    }

    func testHeaderlessInlineBubblesCenterInkWithoutGrowingToAvatarHeight() throws {
        for text in ["Hello", "得很多年", "👨‍👩‍👧‍👦"] {
            for bodySize in [CGFloat(13), CGFloat(28)] {
                for outgoing in [false, true] {
                    for avatarSize in [CGFloat(36), CGFloat(84)] {
                        let message = try TimelineTestFixtures.message(
                            id: 1, senderID: outgoing ? 1 : 2, at: 1, text: text)
                        let environment = TimelineLayoutEnvironment.current(
                            timelineWidth: 900, bodySize: bodySize,
                            caption2Size: bodySize * 11 / 17, avatarSize: avatarSize)
                        var middleHeight: CGFloat?
                        for position in [TimelineGroupPosition.middle, .last] {
                            let row = TimelineRow.message(
                                .init(
                                    entry: .remote(message), isOutgoing: outgoing,
                                    groupPosition: position, showsSenderName: false))
                            let presentation = TimelineRowPresentation.make(
                                row: row, currentUserID: 1, isThreadTimeline: false,
                                environment: environment)
                            let layout = TimelineLayoutEngine().layout(
                                presentation, environment: environment)
                            let bubble = try XCTUnwrap(layout.frames[.bubble])
                            let textFrame = try XCTUnwrap(layout.frames[.text])
                            let geometry = try XCTUnwrap(layout.textGeometry)
                            XCTAssertTrue(geometry.metadataIsInline)
                            let nativeLayout = MessageTextLayout(
                                attributedText: MessageTextContent.attributedText(
                                    text: text, mentions: [], currentUserID: 1,
                                    isOutgoing: outgoing, font: .systemFont(ofSize: bodySize)),
                                metadata: presentation.metadata)
                            nativeLayout.install(geometry: geometry)
                            let ink = nativeLayout.singleLineInkBounds()
                                .offsetBy(dx: textFrame.minX, dy: textFrame.minY)
                            XCTAssertEqual(
                                ink.midY, bubble.midY, accuracy: 1 / environment.displayScale)
                            XCTAssertTrue(bubble.insetBy(dx: -0.5, dy: -0.5).contains(textFrame))
                            if position == .middle {
                                middleHeight = bubble.height
                            } else {
                                XCTAssertEqual(
                                    bubble.height, try XCTUnwrap(middleHeight), accuracy: 0.5)
                                let avatar = try XCTUnwrap(layout.frames[.avatar])
                                let rowBounds = CGRect(origin: .zero, size: layout.size)
                                XCTAssertTrue(rowBounds.contains(avatar))
                                XCTAssertTrue(rowBounds.contains(bubble))
                                if avatar.height > bubble.height {
                                    XCTAssertEqual(
                                        avatar.midY, bubble.midY,
                                        accuracy: 1 / environment.displayScale)
                                } else {
                                    XCTAssertEqual(avatar.maxY, bubble.maxY, accuracy: 0.5)
                                }
                                if avatarSize == 84 {
                                    XCTAssertLessThan(bubble.height, avatar.height)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testDeliveryTransitionsKeepTimestampAndTextGeometryStable() {
        let transitions: [(ConversationMessageDisplayState, Bool)] = [
            (.queued, false), (.sending, false), (.failed, false),
            (.delivered, false), (.delivered, true),
        ]
        for fontSize in [CGFloat(12), CGFloat(28)] {
            let text = MessageTextContent.attributedText(
                text: "A final line near the timestamp", mentions: [], currentUserID: 1,
                isOutgoing: true, font: .systemFont(ofSize: fontSize * 17 / 12))
            let metadata = transitions.map { state, isRead in
                MessageMetadata(
                    time: "12:34", state: state, isOutgoing: true, isRead: isRead,
                    fontSize: fontSize)
            }
            for width in [metadata[0].size.width, metadata[0].size.width + 160] {
                let baseline = MessageTextLayout(attributedText: text, metadata: metadata[0])
                    .geometry(for: width)
                for value in metadata.dropFirst() {
                    let geometry = MessageTextLayout(attributedText: text, metadata: value)
                        .geometry(for: width)
                    XCTAssertEqual(geometry.size, baseline.size)
                    XCTAssertEqual(geometry.metadataFrame, baseline.metadataFrame)
                    XCTAssertEqual(geometry.metadataIsInline, baseline.metadataIsInline)
                    XCTAssertTrue(
                        geometry.metadataFrame.insetBy(dx: -0.001, dy: -0.001)
                            .contains(value.statusFrame(in: geometry.metadataFrame)))
                }
            }
        }
    }

    #if os(macOS)
        func testStaticNativeDeliveryKeepsCanonicalInkAcrossAppearanceAndFittedSizes() throws {
            func inkBounds(_ bitmap: NSBitmapImageRep) -> CGRect {
                var ink = CGRect.null
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide
                    where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                        ink = ink.union(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
                    }
                }
                return ink
            }
            let view = TimelineDeliveryStatusView(frame: .zero)
            for appearanceName in [
                NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua,
            ] {
                view.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                for fontSize in [CGFloat(11), CGFloat(28)] {
                    for (state, read) in [
                        (ConversationMessageDisplayState.queued, false),
                        (.failed, false), (.delivered, false), (.delivered, true),
                    ] {
                        let metadata = MessageMetadata(
                            time: "12:34", state: state, isOutgoing: true, isRead: read,
                            fontSize: fontSize)
                        let nominal = metadata.statusFrame(
                            in: CGRect(origin: .zero, size: metadata.size)
                        ).size
                        // Include a compressed slot: the shared content scales around
                        // its center rather than simply resizing the check path.
                        for fit in [CGFloat(1), CGFloat(0.65)] {
                            view.frame = CGRect(
                                origin: .zero,
                                size: CGSize(
                                    width: ceil(nominal.width * fit),
                                    height: ceil(nominal.height * fit)))
                            view.configure(metadata)
                            view.layoutSubtreeIfNeeded()
                            let bitmap = try XCTUnwrap(
                                view.bitmapImageRepForCachingDisplay(in: view.bounds))
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            let nominalSize = MessageDeliveryStatusView.layoutSize(
                                for: metadata.statusFontSize,
                                checkSeparation: metadata.checkSeparation)
                            let scale = min(
                                1, view.bounds.width / nominalSize.width,
                                view.bounds.height / nominalSize.height)
                            let canonical = NSHostingView(
                                rootView: MessageDeliveryStatusView(
                                    status: try XCTUnwrap(metadata.status),
                                    size: metadata.statusFontSize,
                                    checkSeparation: metadata.checkSeparation,
                                    checkHeight: metadata.digitHeight
                                )
                                .foregroundStyle(Color(metadata.foreground))
                                .fixedSize()
                                .scaleEffect(scale)
                                .frame(width: view.bounds.width, height: view.bounds.height)
                                .environment(
                                    \.displayScale,
                                    CGFloat(bitmap.pixelsWide) / view.bounds.width))
                            canonical.sizingOptions = []
                            canonical.appearance = view.appearance
                            canonical.frame = view.bounds
                            canonical.layoutSubtreeIfNeeded()
                            let reference = try XCTUnwrap(
                                canonical.bitmapImageRepForCachingDisplay(in: canonical.bounds))
                            canonical.cacheDisplay(in: canonical.bounds, to: reference)
                            let actualInk = inkBounds(bitmap)
                            let expectedInk = inkBounds(reference)
                            let diagnostic =
                                "\(state), read=\(read), font=\(fontSize), fit=\(fit), appearance=\(appearanceName)"
                            XCTAssertFalse(actualInk.isNull, diagnostic)
                            XCTAssertEqual(
                                actualInk.minX, expectedInk.minX, accuracy: 1, diagnostic)
                            XCTAssertEqual(
                                actualInk.maxX, expectedInk.maxX, accuracy: 1, diagnostic)
                            XCTAssertEqual(
                                actualInk.minY, expectedInk.minY, accuracy: 1, diagnostic)
                            XCTAssertEqual(
                                actualInk.maxY, expectedInk.maxY, accuracy: 1, diagnostic)
                            // Bounds alone would allow a vertically mirrored check.
                            // Permit edge antialiasing differences from the cached
                            // backing scale, but require the same glyph coverage.
                            var difference: CGFloat = 0
                            var coverage: CGFloat = 0
                            for y in 0..<min(bitmap.pixelsHigh, reference.pixelsHigh) {
                                for x in 0..<min(bitmap.pixelsWide, reference.pixelsWide) {
                                    let actual = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                                    let expected =
                                        reference.colorAt(x: x, y: y)?.alphaComponent ?? 0
                                    difference += abs(actual - expected)
                                    coverage += expected
                                }
                            }
                            if difference / max(coverage, 1) >= 0.65
                                || abs(actualInk.maxY - expectedInk.maxY) > 1
                                || abs(actualInk.maxX - expectedInk.maxX) > 1
                            {
                                for (name, rendered) in [
                                    ("Native", bitmap), ("Reference", reference),
                                ] {
                                    let image = NSImage(size: view.bounds.size)
                                    image.addRepresentation(rendered)
                                    let attachment = XCTAttachment(image: image)
                                    attachment.name = "\(name) \(diagnostic)"
                                    attachment.lifetime = .keepAlways
                                    add(attachment)
                                }
                            }
                            XCTAssertLessThan(difference / max(coverage, 1), 0.65, diagnostic)
                        }
                    }
                }
            }
            view.configure(nil)
            XCTAssertTrue(view.isHidden)
        }

        func testNativeCodeSelectionAndScrollResetAcrossMessageIdentity() throws {
            let source = "```swift\n" + String(repeating: "let value = 123; ", count: 40) + "\n```"
            let prepared = try preparedText(source, width: 180)
            let content = MessageTextContent(
                text: source, mentions: [], currentUserID: 1, isOutgoing: false, action: nil,
                metadata: prepared.metadata, geometry: prepared.geometry, fontSize: 14,
                preparedText: prepared.preparedText)
            let text = AppKitMessageTextView(geometry: prepared.geometry)
            text.frame = CGRect(origin: .zero, size: prepared.geometry.size)
            text.apply(content, resetSelection: true)
            text.layoutSubtreeIfNeeded()
            var code = try XCTUnwrap(
                text.subviews.compactMap { $0 as? MessageCodeScrollView }.first { !$0.isHidden })
            var viewport: NSScrollView = code
            var document = try XCTUnwrap(viewport.documentView as? NSTextView)
            document.setSelectedRange(NSRange(location: 0, length: 3))
            viewport.contentView.scroll(to: CGPoint(x: 50, y: 0))
            XCTAssertGreaterThan(viewport.contentView.bounds.minX, 0)
            text.apply(content, resetSelection: false)
            XCTAssertEqual(document.selectedRange().length, 3)
            XCTAssertGreaterThan(viewport.contentView.bounds.minX, 0)

            // Identical prepared text retains the attachment identity. A different
            // message must still reset both selection and the horizontal position.
            text.apply(content, resetSelection: true)
            code = try XCTUnwrap(
                text.subviews.compactMap { $0 as? MessageCodeScrollView }.first { !$0.isHidden })
            viewport = code
            document = try XCTUnwrap(viewport.documentView as? NSTextView)
            XCTAssertEqual(document.selectedRange(), NSRange(location: 0, length: 0))
            XCTAssertEqual(viewport.contentView.bounds.origin, .zero)
            document.setSelectedRange(NSRange(location: 0, length: 3))
            viewport.contentView.scroll(to: CGPoint(x: 50, y: 0))
            text.clear()
            text.apply(content, resetSelection: true)
            code = try XCTUnwrap(
                text.subviews.compactMap { $0 as? MessageCodeScrollView }.first { !$0.isHidden })
            viewport = code
            document = try XCTUnwrap(viewport.documentView as? NSTextView)
            XCTAssertEqual(document.selectedRange(), NSRange(location: 0, length: 0))
            XCTAssertEqual(viewport.contentView.bounds.origin, .zero)

            document.setSelectedRange(NSRange(location: 0, length: 3))
            viewport.contentView.scroll(to: CGPoint(x: 50, y: 0))
            let shiftedSource = "A new prefix\n" + source
            let shifted = try preparedText(shiftedSource, width: 180)
            text.apply(
                MessageTextContent(
                    text: shiftedSource, mentions: [], currentUserID: 1, isOutgoing: false,
                    action: nil, metadata: shifted.metadata, geometry: shifted.geometry,
                    fontSize: 14, preparedText: shifted.preparedText),
                resetSelection: true)
            code = try XCTUnwrap(
                text.subviews.compactMap { $0 as? MessageCodeScrollView }.first { !$0.isHidden })
            viewport = code
            document = try XCTUnwrap(viewport.documentView as? NSTextView)
            XCTAssertEqual(document.selectedRange(), NSRange(location: 0, length: 0))
            XCTAssertEqual(viewport.contentView.bounds.origin, .zero)
        }

        func testNativeTextPreservesSelectionAndUsesCurrentLinkActions() throws {
            var opened: [String] = []
            let prepared = try preparedText("Hello https://example.com", width: 340)
            func content(_ prefix: String?) -> MessageTextContent {
                MessageTextContent(
                    text: "Hello https://example.com", mentions: [], currentUserID: 1,
                    isOutgoing: false,
                    action: prefix.map { prefix in { opened.append(prefix + $0.absoluteString) } },
                    metadata: prepared.metadata, geometry: prepared.geometry, fontSize: 14,
                    preparedText: prepared.preparedText
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

        func testNativeLinkAndSpoilerHoverUseHandWithoutDisablingTextSelection() throws {
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

            let source = "Before ||hidden text|| after"
            let spoiler = try preparedText(source, width: 136)
            text.apply(
                MessageTextContent(
                    text: source, mentions: [], currentUserID: 1,
                    isOutgoing: false, action: nil, metadata: spoiler.metadata,
                    geometry: spoiler.geometry, fontSize: 14),
                resetSelection: true)
            text.setSelectedRange(NSRange(location: 0, length: 6))
            let hidden = (text.string as NSString).range(of: "hidden text")
            let coordinator = try XCTUnwrap(text.delegate as? MessageTextContent.Coordinator)
            try hover(hidden.location)
            XCTAssertEqual(NSCursor.current, .pointingHand)
            try hover(1)
            XCTAssertEqual(NSCursor.current, .iBeam)
            XCTAssertTrue(coordinator.toggleSpoiler(at: hidden.location))
            try hover(hidden.location)
            XCTAssertEqual(NSCursor.current, .pointingHand)
            XCTAssertTrue(coordinator.toggleSpoiler(at: hidden.location))
            try hover(hidden.location)
            XCTAssertEqual(NSCursor.current, .pointingHand)
            XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 6))
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
                    metadata: prepared.metadata, geometry: prepared.geometry, fontSize: 14,
                    preparedText: prepared.preparedText
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
        }
    #endif

    func testWidthOnlyMeasurementPreservesFinalGeometryAcrossReuseAndCodeFitting() {
        let measurement = MessageTextLayout()
        let sources = [
            "", "Hello", "现在基本内部都有大规模的 AI 扫 bug 👨‍👩‍👧‍👦",
            "First line\nLast line\n", "**Bold** and ||concealed||",
            "Before\n```swift\n" + String(repeating: "let value = 123; ", count: 30)
                + "\n```\nAfter",
        ]
        for fontSize: CGFloat in [13, 28] {
            for source in sources {
                for metadata: MessageMetadata? in [
                    nil,
                    MessageMetadata(
                        time: "12:34", state: nil, isOutgoing: false, fontSize: fontSize),
                    MessageMetadata(
                        time: "12:34", state: .delivered, isOutgoing: true, isRead: true,
                        fontSize: fontSize),
                ] {
                    func text() -> NSAttributedString {
                        MessageTextContent.attributedText(
                            text: source, mentions: [], currentUserID: 1, isOutgoing: false,
                            font: .systemFont(ofSize: fontSize))
                    }
                    // The reference performs the old intrinsic-width *and height*
                    // measurement, including its intermediate code-attachment fit.
                    let reference = MessageTextLayout(attributedText: text(), metadata: metadata)
                    let expectedSize = reference.idealSize
                    measurement.update(attributedText: text(), metadata: metadata)
                    XCTAssertEqual(measurement.idealWidth, expectedSize.width)
                    for width in [CGFloat(80), CGFloat(240), expectedSize.width] {
                        XCTAssertEqual(
                            measurement.geometry(for: width), reference.geometry(for: width),
                            "Width-only sizing must preserve line breaks, footer and code frames.")
                    }
                    XCTAssertEqual(measurement.idealSize, expectedSize)
                    measurement.install(geometry: measurement.geometry(for: 120))
                    XCTAssertEqual(measurement.idealWidth, expectedSize.width)
                    XCTAssertEqual(
                        measurement.fittingSize(width: nil),
                        reference.geometry(for: expectedSize.width).size)
                }
            }
        }
    }

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

    func testFooterUsesLowerTrailingInsetWithoutChangingBodyWrapping() throws {
        for bodySize in [CGFloat(17), CGFloat(28)] {
            for width in [CGFloat(320), CGFloat(600)] {
                let message = try TimelineTestFixtures.message(
                    id: 1, senderID: 1, at: 1,
                    fields: ["message": "A longer first line that wraps naturally\nEnd"])
                let row = TimelineRow.message(
                    .init(
                        entry: .remote(message), isOutgoing: true, groupPosition: .last,
                        showsSenderName: false))
                let environment = TimelineLayoutEnvironment.current(
                    timelineWidth: width, bodySize: bodySize,
                    caption2Size: bodySize * 11 / 17)
                let presentation = TimelineRowPresentation.make(
                    row: row, currentUserID: 1, isThreadTimeline: false,
                    environment: environment)
                let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
                let bubble = try XCTUnwrap(layout.frames[.bubble])
                let text = try XCTUnwrap(layout.frames[.text])
                let geometry = try XCTUnwrap(layout.textGeometry)
                let footer = geometry.metadataFrame.offsetBy(dx: text.minX, dy: text.minY)
                XCTAssertGreaterThan(footer.maxX, text.minX + geometry.containerWidth)
                XCTAssertLessThan(footer.maxX, bubble.maxX)
                XCTAssertLessThanOrEqual(footer.maxY, bubble.maxY)
                if geometry.metadataIsInline {
                    XCTAssertGreaterThan(geometry.metadataFrame.maxY, geometry.lastLineBounds.maxY)
                    XCTAssertGreaterThan(geometry.metadataFrame.minX, geometry.lastLineBounds.maxX)
                } else {
                    XCTAssertGreaterThanOrEqual(
                        geometry.metadataFrame.minY, geometry.bodyBounds.maxY)
                }

                let nativeLayout = MessageTextLayout(
                    attributedText: MessageTextContent.attributedText(
                        text: message.message ?? "", mentions: [], currentUserID: 1,
                        isOutgoing: true, font: .systemFont(ofSize: bodySize)),
                    metadata: presentation.metadata)
                nativeLayout.install(geometry: geometry)
                nativeLayout.layoutManager.ensureLayout(for: nativeLayout.textContainer)
                let installed = nativeLayout.layoutManager.usedRect(for: nativeLayout.textContainer)
                XCTAssertEqual(installed.height, geometry.bodyBounds.height, accuracy: 0.5)
            }
        }
    }

    func testImageCaptionUsesAvailableLastLineForTimestamp() throws {
        let message = try TimelineTestFixtures.message(
            id: 1, at: 1,
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
            row: row, currentUserID: 1,
            isThreadTimeline: false, environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        let bubble = try XCTUnwrap(layout.frames[.bubble])
        let media = try XCTUnwrap(layout.frames[.media])
        let text = try XCTUnwrap(layout.frames[.text])
        let geometry = try XCTUnwrap(layout.textGeometry)
        XCTAssertTrue(geometry.metadataIsInline)
        XCTAssertNil(layout.frames[.metadata])
        XCTAssertEqual(text.minY, media.maxY + 4, accuracy: 0.5)
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
            id: 1, senderID: 2, at: 0,
            hour: 0, minute: 17, fields: ["message": ""])
        let row = TimelineRow.message(
            .init(
                entry: .remote(message), isOutgoing: false,
                groupPosition: .single, showsSenderName: false))
        let environment = TimelineLayoutEnvironment.current(timelineWidth: 320, displayScale: 1.1)
        let presentation = TimelineRowPresentation.make(
            row: row, currentUserID: 1,
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
        func testInlineTimestampRetainsTrailingDigitOutsideBodyContainer() throws {
            let metadata = MessageMetadata(time: "00:48", state: nil, isOutgoing: false)
            let layout = MessageTextLayout(
                attributedText: MessageTextContent.attributedText(
                    text: "那你老婆是美国人🤔？", mentions: [], currentUserID: 1,
                    isOutgoing: false, font: .systemFont(ofSize: 17)),
                metadata: metadata)
            let geometry = layout.geometry(for: layout.idealSize.width)
            let view = AppKitMessageTextView(geometry: geometry)
            view.contentLayout.update(attributedText: layout.storage, metadata: metadata)
            view.contentLayout.install(geometry: geometry)
            view.frame = CGRect(origin: .zero, size: geometry.size)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let firstColumn = Int(ceil(geometry.containerWidth * scale))
            var trailingInk = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in firstColumn..<bitmap.pixelsWide {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                        trailingInk += 1
                    }
                }
            }
            XCTAssertGreaterThan(
                trailingInk, 0,
                "The final timestamp digit must draw beyond the body's narrower TextKit container.")
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor.white.setFill()
            view.bounds.fill()
            bitmap.draw(in: view.bounds)
            image.unlockFocus()
            let attachment = XCTAttachment(image: image)
            attachment.name = "Inline timestamp trailing digit"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

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

    func testConcealedSpoilerCannotBeCopiedUntilRevealedAndReconcealClampsSelection() throws {
        let source = "Before ||secret|| after"
        let prepared = try preparedText(source, width: 240)
        #if os(macOS)
            let text = AppKitMessageTextView(geometry: prepared.geometry)
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: prepared.geometry.size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = text
            window.makeFirstResponder(text)
            defer { window.close() }
            let board = NSPasteboard.general
            let saved = (board.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            defer {
                board.clearContents()
                board.writeObjects(saved)
            }
            func select(_ range: NSRange) { text.setSelectedRange(range) }
            func copied() -> String? { board.string(forType: .string) }
        #else
            let text = UIKitMessageTextView(geometry: prepared.geometry)
            text.allowsSelection = true
            let host = UIViewController()
            host.view.addSubview(text)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            text.frame = CGRect(origin: .zero, size: prepared.geometry.size)
            defer { window.isHidden = true }
            let saved = UIPasteboard.general.items
            defer { UIPasteboard.general.items = saved }
            func select(_ range: NSRange) { text.selectedRange = range }
            func copied() -> String? { UIPasteboard.general.string }
        #endif
        text.apply(
            MessageTextContent(
                text: source, mentions: [], currentUserID: 1,
                isOutgoing: false, action: nil, metadata: prepared.metadata,
                geometry: prepared.geometry, fontSize: 14,
                preparedText: prepared.preparedText), resetSelection: true)
        let coordinator = try XCTUnwrap(text.delegate as? MessageTextContent.Coordinator)
        let full = NSRange(location: 0, length: text.contentLayout.storage.length)
        let hidden = (text.contentLayout.storage.string as NSString).range(of: "secret")
        let safe = text.contentLayout.selectableRange(
            full, previous: NSRange(location: 0, length: 0))
        XCTAssertEqual(safe, NSRange(location: 0, length: hidden.location))
        select(full)
        text.copy(nil)
        XCTAssertEqual(copied(), "Before ")
        XCTAssertFalse(text.contentLayout.accessibilityText.contains("secret"))

        XCTAssertTrue(coordinator.toggleSpoiler(at: hidden.location))
        select(full)
        text.copy(nil)
        XCTAssertEqual(copied(), "Before secret after")
        XCTAssertTrue(coordinator.toggleSpoiler(at: hidden.location))
        text.copy(nil)
        XCTAssertEqual(copied(), "Before ")

        let suffix = NSRange(location: NSMaxRange(hidden), length: full.length - NSMaxRange(hidden))
        select(suffix)
        text.copy(nil)
        XCTAssertEqual(copied(), " after", "Concealment must not disable ordinary selectable text.")
    }

    func testNestedListUsesIndentedParagraphAndGlyphGeometry() throws {
        let layout = makeLayout("- First item\n- Second item\n  1. Nested ordered item")
        _ = layout.geometry(for: 280)
        let source = layout.storage.string as NSString
        let parent = source.range(of: "• Second")
        let nested = source.range(of: "1. Nested")
        XCTAssertNotEqual(parent.location, NSNotFound)
        XCTAssertNotEqual(nested.location, NSNotFound)
        let parentStyle = try XCTUnwrap(
            layout.storage.attribute(
                .paragraphStyle,
                at: parent.location, effectiveRange: nil) as? NSParagraphStyle)
        let nestedStyle = try XCTUnwrap(
            layout.storage.attribute(
                .paragraphStyle,
                at: nested.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(nestedStyle.firstLineHeadIndent, parentStyle.firstLineHeadIndent)
        func glyphBounds(_ index: Int) -> CGRect {
            let glyphs = layout.layoutManager.glyphRange(
                forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            return layout.layoutManager.boundingRect(
                forGlyphRange: glyphs, in: layout.textContainer)
        }
        XCTAssertGreaterThan(glyphBounds(nested.location).minX, glyphBounds(parent.location).minX)
    }

    func testNativeCodeHeadersCopyRawBlocksIndependentlyAndDisableInPreview() async throws {
        let raw = "\tconst html = \"<b>raw</b>\";  \n\n// **literal** @[uid:2]\n"
        let source = "```js\n" + raw + "```\n\n    second  \n"
        let prepared = try preparedText(source, width: 180)
        #if os(macOS)
            let text = AppKitMessageTextView(geometry: prepared.geometry)
            let board = NSPasteboard.general
            let saved = (board.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            defer {
                board.clearContents()
                board.writeObjects(saved)
            }
            func copied() -> String? { board.string(forType: .string) }
            func press(_ block: MessageCodeScrollView) { block.copyButton.performClick(nil) }
            func feedback(_ block: MessageCodeScrollView) -> String? {
                block.copyButton.accessibilityLabel()
            }
        #else
            let text = UIKitMessageTextView(geometry: prepared.geometry)
            let saved = UIPasteboard.general.items
            defer { UIPasteboard.general.items = saved }
            func copied() -> String? { UIPasteboard.general.string }
            func press(_ block: MessageCodeScrollView) {
                block.copyButton.sendActions(for: .touchUpInside)
            }
            func feedback(_ block: MessageCodeScrollView) -> String? {
                block.copyButton.accessibilityLabel
            }
        #endif
        var content = MessageTextContent(
            text: source, mentions: [], currentUserID: 1, isOutgoing: false, action: nil,
            metadata: prepared.metadata, geometry: prepared.geometry, fontSize: 14,
            preparedText: prepared.preparedText)
        text.apply(content, resetSelection: true)
        defer { text.clear() }
        let blocks = text.subviews.compactMap { $0 as? MessageCodeScrollView }
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(blocks.count, 2)
        let first = try XCTUnwrap(blocks.first)
        let second = try XCTUnwrap(blocks.last)
        let attachments = text.contentLayout.codeBlocks.map(\.1)
        XCTAssertEqual(attachments.first?.language, "js")
        XCTAssertNil(attachments.last?.language)
        for (geometry, attachment) in text.contentLayout.codeBlocks {
            XCTAssertEqual(
                geometry.frame.height, attachment.codeSize.height + attachment.headerHeight,
                accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(attachment.headerHeight, 20)
        }
        #if os(macOS)
            let originalSelection = text.selectedRange()
        #else
            let originalSelection = text.selectedRange
        #endif
        press(first)
        XCTAssertEqual(copied(), raw)
        XCTAssertEqual(feedback(first), AppLanguage.localized("Copied"))
        XCTAssertEqual(feedback(second), AppLanguage.localized("Copy"))
        try await Task.sleep(for: .milliseconds(1100))
        press(second)
        XCTAssertEqual(copied(), "second  \n")
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertEqual(feedback(first), AppLanguage.localized("Copy"))
        XCTAssertEqual(feedback(second), AppLanguage.localized("Copied"))
        #if os(macOS)
            XCTAssertEqual(text.selectedRange(), originalSelection)
        #else
            XCTAssertEqual(text.selectedRange, originalSelection)
        #endif
        content.copyEnabled = false
        text.apply(content, resetSelection: false)
        XCTAssertFalse(first.copyButton.isEnabled)
        press(first)
        XCTAssertEqual(copied(), "second  \n", "An inactive preview must not copy.")
        content.copyEnabled = true
        text.apply(content, resetSelection: false)
        press(first)
        XCTAssertEqual(copied(), raw)
        text.apply(content, resetSelection: true)
        let rebound = try XCTUnwrap(
            text.subviews.compactMap { $0 as? MessageCodeScrollView }
                .filter { !$0.isHidden }.min { $0.frame.minY < $1.frame.minY })
        XCTAssertEqual(feedback(rebound), AppLanguage.localized("Copy"))
    }

    func testPlainFencesInheritBubbleContrastWhileKnownTokenlessCodeUsesSyntaxTheme() throws {
        for outgoing in [false, true] {
            for language in [nil, "not-a-real-language", "markdown"] as [String?] {
                let rendered = try fencedCode(
                    "plainidentifier", language: language, outgoing: outgoing)
                let body = try XCTUnwrap(
                    rendered.body.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                        as? BubbleNativeColor)
                let code = try XCTUnwrap(
                    rendered.attachment.attributedCode.attribute(
                        .foregroundColor, at: 0, effectiveRange: nil) as? BubbleNativeColor)
                for dark in [false, true] {
                    XCTAssertEqual(try rgba(code, dark: dark), try rgba(body, dark: dark))
                }
            }
        }
        let incoming = try fencedCode("plainidentifier", language: "javascript", outgoing: false)
        let outgoing = try fencedCode("plainidentifier", language: "JS", outgoing: true)
        for dark in [false, true] {
            let first = try XCTUnwrap(
                incoming.attachment.attributedCode.attribute(
                    .foregroundColor, at: 0, effectiveRange: nil) as? BubbleNativeColor)
            let second = try XCTUnwrap(
                outgoing.attachment.attributedCode.attribute(
                    .foregroundColor, at: 0, effectiveRange: nil) as? BubbleNativeColor)
            XCTAssertEqual(try rgba(first, dark: dark), try rgba(second, dark: dark))
            XCTAssertNotEqual(try rgba(second, dark: dark), try rgba(.white, dark: dark))
        }
    }

    func testCodeViewportReuseAndThemeChangesKeepBubbleDerivedSurface() throws {
        let viewport = MessageCodeScrollView()
        for outgoing in [false, true, false] {
            let rendered = try fencedCode("plainidentifier", language: nil, outgoing: outgoing)
            let foreground = try XCTUnwrap(
                rendered.body.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                    as? BubbleNativeColor)
            for dark in [false, true, false] {
                #if os(macOS)
                    viewport.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    viewport.apply(rendered.attachment)
                #else
                    viewport.overrideUserInterfaceStyle = dark ? .dark : .light
                    viewport.apply(rendered.attachment, allowsSelection: true)
                #endif
                let background = try XCTUnwrap(viewport.backgroundColor)
                let actual = try rgba(background, dark: dark)
                var expected = try rgba(foreground, dark: dark)
                expected[3] *= 0.08
                for (actual, expected) in zip(actual, expected) {
                    XCTAssertEqual(actual, expected, accuracy: 0.001)
                }
            }
        }
    }

    func testIgnoredNestedSyntaxScopesInheritTokenColorAndDiffBackgroundIsTokenOnly() throws {
        let rust = try fencedCode("b'\\n'", language: "rust", outgoing: true).attachment
            .attributedCode
        let source = rust.string as NSString
        let escape = source.range(of: "\\n")
        let outer = try XCTUnwrap(
            rust.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? BubbleNativeColor)
        let inner = try XCTUnwrap(
            rust.attribute(.foregroundColor, at: escape.location, effectiveRange: nil)
                as? BubbleNativeColor)
        for dark in [false, true] {
            XCTAssertEqual(try rgba(inner, dark: dark), try rgba(outer, dark: dark))
        }
        let diff = try fencedCode(
            "+ added\n- removed\n unchanged", language: "diff", outgoing: false
        ).attachment.attributedCode
        let text = diff.string as NSString
        XCTAssertNotNil(
            diff.attribute(
                .backgroundColor, at: text.range(of: "added").location, effectiveRange: nil))
        XCTAssertNotNil(
            diff.attribute(
                .backgroundColor, at: text.range(of: "removed").location, effectiveRange: nil))
        XCTAssertNil(
            diff.attribute(
                .backgroundColor, at: text.range(of: "unchanged").location, effectiveRange: nil))
    }

    func testInlineCodeInheritsNestedBodyStylesAndKeepsLinksAndSpoilers() throws {
        for outgoing in [false, true] {
            let value = MessageTextContent.attributedText(
                text:
                    "Plain **`bold`** __`italic`__ [link `linked`](https://example.com) ||`secret`||",
                mentions: [], currentUserID: 1, isOutgoing: outgoing,
                font: .systemFont(ofSize: 14), linksEnabled: true)
            let text = value.string as NSString
            func color(_ word: String, _ key: NSAttributedString.Key = .foregroundColor) throws
                -> BubbleNativeColor
            {
                try XCTUnwrap(
                    value.attribute(key, at: text.range(of: word).location, effectiveRange: nil)
                        as? BubbleNativeColor)
            }
            for dark in [false, true] {
                XCTAssertEqual(
                    try rgba(color("bold"), dark: dark), try rgba(color("Plain"), dark: dark))
                XCTAssertEqual(
                    try rgba(color("linked"), dark: dark), try rgba(color("link "), dark: dark))
                var expected = try rgba(color("linked"), dark: dark)
                expected[3] *= 0.10
                let background = try rgba(color("linked", .backgroundColor), dark: dark)
                for (actual, expected) in zip(background, expected) {
                    XCTAssertEqual(actual, expected, accuracy: 0.001)
                }
            }
            let bold = try XCTUnwrap(
                value.attribute(.font, at: text.range(of: "bold").location, effectiveRange: nil)
                    as? BubbleNativeFont)
            let italic = try XCTUnwrap(
                value.attribute(.font, at: text.range(of: "italic").location, effectiveRange: nil)
                    as? BubbleNativeFont)
            #if os(macOS)
                XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
                XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
            #else
                XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
                XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
            #endif
            XCTAssertEqual(
                value.attribute(.link, at: text.range(of: "linked").location, effectiveRange: nil)
                    as? URL, URL(string: "https://example.com"))
            let layout = MessageTextLayout(attributedText: value, metadata: nil)
            XCTAssertTrue(layout.layoutManager.isConcealed(at: text.range(of: "secret").location))
            XCTAssertFalse(layout.accessibilityText.contains("secret"))
        }
    }

    func testFencedCodeViewportDoesNotWrapOrExceedSharedGeometry() throws {
        let code = String(repeating: "let longValue = 123; ", count: 30)
        let source = "Before\n```swift\n\(code)\n```\nAfter"
        let layout = makeLayout(source)
        let wide = layout.geometry(for: 220)
        let narrow = layout.geometry(for: 140)
        let wideCode = try XCTUnwrap(wide.codeBlocks.first)
        let narrowCode = try XCTUnwrap(narrow.codeBlocks.first)
        XCTAssertEqual(wide.codeBlocks.count, 1)
        XCTAssertLessThanOrEqual(narrowCode.frame.maxX, narrow.size.width + 0.5)
        XCTAssertLessThanOrEqual(narrow.bodyBounds.maxX, narrow.size.width + 0.5)
        XCTAssertEqual(wideCode.frame.height, narrowCode.frame.height, accuracy: 0.5)
        let attachment = try XCTUnwrap(
            layout.storage.attribute(
                .bubbleCodeBlock,
                at: narrowCode.characterIndex, effectiveRange: nil) as? MessageCodeAttachment)
        XCTAssertGreaterThan(attachment.naturalSize.width, narrowCode.frame.width)
        XCTAssertEqual(attachment.bounds.width, narrowCode.frame.width, accuracy: 0.5)
        let displayed = makeLayout(source)
        displayed.install(geometry: narrow)
        let displayedAttachment = try XCTUnwrap(displayed.codeBlocks.first?.1)
        XCTAssertEqual(displayedAttachment.bounds.width, narrowCode.frame.width, accuracy: 0.5)
        let glyphs = displayed.layoutManager.glyphRange(
            forCharacterRange: NSRange(location: narrowCode.characterIndex, length: 1),
            actualCharacterRange: nil)
        displayed.layoutManager.ensureLayout(for: displayed.textContainer)
        let bounds = displayed.layoutManager.boundingRect(
            forGlyphRange: glyphs, in: displayed.textContainer)
        XCTAssertEqual(bounds.minX, narrowCode.frame.minX, accuracy: 0.5)
        XCTAssertEqual(bounds.minY, narrowCode.frame.minY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(narrow.metadataFrame.minY, narrowCode.frame.maxY)
    }

    func testPreparedTextKeepsEachLayoutsCodeAttachmentBoundsIndependent() throws {
        let source =
            "Before @[uid:2] [link](https://example.com) ||secret||\n```swift\n"
            + String(repeating: "let value = 123; ", count: 30) + "\n```\nAfter"
        let prepared = try preparedText(source, width: 240)
        let body = prepared.preparedText
        let measurement = MessageTextLayout(
            attributedText: body.makeMeasurementText(mentions: [], fontSize: 14),
            metadata: prepared.metadata)
        let narrow = measurement.geometry(for: 140)
        let wide = measurement.geometry(for: 240)
        func installed(_ geometry: MessageTextGeometry, enabled: Bool) -> MessageTextLayout {
            let layout = MessageTextLayout()
            _ = MessageTextContent(
                text: source, mentions: [], currentUserID: 1, isOutgoing: false,
                action: enabled ? { _ in } : nil, mentionAction: enabled ? { _ in } : nil,
                metadata: prepared.metadata, geometry: geometry, fontSize: 14,
                preparedText: body
            ).update(layout, coordinator: .init())
            return layout
        }
        let preview = installed(narrow, enabled: false)
        let live = installed(wide, enabled: true)
        let previewCode = try XCTUnwrap(preview.codeBlocks.first?.1)
        let liveCode = try XCTUnwrap(live.codeBlocks.first?.1)
        XCTAssertEqual(previewCode.bounds.width, try XCTUnwrap(narrow.codeBlocks.first).frame.width)
        XCTAssertEqual(liveCode.bounds.width, try XCTUnwrap(wide.codeBlocks.first).frame.width)
        let previewWidth = previewCode.bounds.width
        _ = measurement.geometry(for: 320)
        XCTAssertEqual(previewCode.bounds.width, previewWidth)
        XCTAssertEqual(liveCode.bounds.width, try XCTUnwrap(wide.codeBlocks.first).frame.width)

        let text = live.storage.string as NSString
        let link = text.range(of: "link").location
        let mention = text.range(of: "@User 2").location
        let spoiler = text.range(of: "secret").location
        for index in [link, mention] {
            XCTAssertNotNil(live.storage.attribute(.link, at: index, effectiveRange: nil))
            XCTAssertNil(preview.storage.attribute(.link, at: index, effectiveRange: nil))
        }
        XCTAssertNotNil(preview.storage.attribute(.bubbleURL, at: link, effectiveRange: nil))
        XCTAssertNotNil(
            preview.storage.attribute(.bubbleMentionID, at: mention, effectiveRange: nil))
        XCTAssertTrue(live.layoutManager.isConcealed(at: spoiler))
        let coordinator = MessageTextContent.Coordinator()
        coordinator.layout = preview
        XCTAssertTrue(coordinator.toggleSpoiler(at: spoiler))
        XCTAssertFalse(preview.layoutManager.isConcealed(at: spoiler))
        XCTAssertTrue(live.layoutManager.isConcealed(at: spoiler))

        // Replacing a code attachment with identical geometry must still fit its
        // new bounds; an unchanged installed size is not an unchanged text graph.
        preview.update(
            attributedText: body.makeAttributedText(linksEnabled: false, mentionsEnabled: false),
            metadata: prepared.metadata)
        preview.install(geometry: narrow)
        let replacement = try XCTUnwrap(preview.codeBlocks.first?.1)
        XCTAssertEqual(replacement.bounds.width, previewWidth)
    }

    func testPreparedTextKeepsIndependentLinkPermissionsAndDynamicColors() throws {
        let source =
            "Hello @[uid:1] [link](https://example.com) ||secret|| "
            + "[nested @[uid:2]](https://example.com/mention)"
        let prepared = try preparedText(source, width: 240).preparedText
        for linksEnabled in [false, true] {
            for mentionsEnabled in [false, true] {
                let value = prepared.makeAttributedText(
                    linksEnabled: linksEnabled, mentionsEnabled: mentionsEnabled)
                let reference = MessageTextContent.attributedText(
                    text: source, mentions: [], currentUserID: 1, isOutgoing: false,
                    font: .systemFont(ofSize: 14),
                    linksEnabled: linksEnabled, mentionsEnabled: mentionsEnabled)
                let text = value.string as NSString
                XCTAssertEqual(value.string, reference.string)
                for word in ["Hello", "@User 1", "link", "secret", "@User 2"] {
                    let index = text.range(of: word).location
                    XCTAssertEqual(
                        value.attribute(.link, at: index, effectiveRange: nil) as? URL,
                        reference.attribute(.link, at: index, effectiveRange: nil) as? URL)
                    let color = try XCTUnwrap(
                        value.attribute(.foregroundColor, at: index, effectiveRange: nil)
                            as? BubbleNativeColor)
                    let expected = try XCTUnwrap(
                        reference.attribute(.foregroundColor, at: index, effectiveRange: nil)
                            as? BubbleNativeColor)
                    for dark in [false, true] {
                        XCTAssertEqual(try rgba(color, dark: dark), try rgba(expected, dark: dark))
                    }
                }
            }
        }
        let enlarged = prepared.makeMeasurementText(mentions: [], fontSize: 28)
        XCTAssertEqual(
            (enlarged.attribute(.font, at: 0, effectiveRange: nil) as? BubbleNativeFont)?.pointSize,
            28)
    }

    #if os(macOS)
        func testCodeViewportKeepsHeaderFixedAndRoutesContentHits() throws {
            let source = "```swift\n" + String(repeating: "let value = 123; ", count: 40) + "\n```"
            let prepared = try preparedText(source, width: 180)
            let text = AppKitMessageTextView(geometry: prepared.geometry)
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: prepared.geometry.size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = text
            defer { window.close() }
            text.apply(
                MessageTextContent(
                    text: source, mentions: [], currentUserID: 1,
                    isOutgoing: false, action: nil, metadata: prepared.metadata,
                    geometry: prepared.geometry, fontSize: 14), resetSelection: true)
            text.layoutSubtreeIfNeeded()
            let code = try XCTUnwrap(
                text.subviews.compactMap { $0 as? MessageCodeScrollView }.first)
            let document = try XCTUnwrap(code.documentView as? NSTextView)
            let clip = code.contentView
            let maximumOffset = document.frame.width - clip.bounds.width
            XCTAssertGreaterThan(maximumOffset, 120)
            XCTAssertTrue(document.isSelectable)
            let headerFrame = code.copyButton.convert(code.copyButton.bounds, to: text)
            XCTAssertLessThanOrEqual(code.copyButton.frame.maxY, clip.frame.minY)

            // Drive native clip bounds directly: a windowless Quartz event tests
            // AppKit's event/animation environment, not our layout or hit routing.
            for offset in [CGFloat.zero, 120, maximumOffset] {
                clip.scroll(to: CGPoint(x: offset, y: 0))
                code.reflectScrolledClipView(clip)
                text.layoutSubtreeIfNeeded()
                XCTAssertEqual(clip.bounds.minX, offset, accuracy: 0.5)
                XCTAssertEqual(
                    code.copyButton.convert(code.copyButton.bounds, to: text), headerFrame)
                let contentPoint = clip.convert(
                    CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: text.superview)
                let contentHit = try XCTUnwrap(text.hitTest(contentPoint))
                XCTAssertTrue(
                    contentHit === document || contentHit.isDescendant(of: document),
                    "Code interaction must reach its selectable document, not the outer message.")
                let copyPoint = code.copyButton.convert(
                    CGPoint(x: code.copyButton.bounds.midX, y: code.copyButton.bounds.midY),
                    to: text.superview)
                XCTAssertTrue(text.hitTest(copyPoint) === code.copyButton)
            }
        }
    #endif

    private func fencedCode(_ code: String, language: String?, outgoing: Bool) throws -> (
        body: NSAttributedString, attachment: MessageCodeAttachment
    ) {
        let body = MessageTextContent.attributedText(
            text: "Body\n```\(language ?? "")\n\(code)\n```",
            mentions: [], currentUserID: 1, isOutgoing: outgoing, font: .systemFont(ofSize: 14))
        var attachment: MessageCodeAttachment?
        body.enumerateAttribute(.bubbleCodeBlock, in: NSRange(location: 0, length: body.length)) {
            value, _, stop in
            if let value = value as? MessageCodeAttachment {
                attachment = value
                stop.pointee = true
            }
        }
        return (body, try XCTUnwrap(attachment))
    }

    private func rgba(_ color: BubbleNativeColor, dark: Bool) throws -> [CGFloat] {
        #if os(macOS)
            var resolved: NSColor?
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
            let value = try XCTUnwrap(resolved)
            return [
                value.redComponent, value.greenComponent, value.blueComponent, value.alphaComponent,
            ]
        #else
            let resolved = color.resolvedColor(
                with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            return [red, green, blue, alpha]
        #endif
    }

    private func preparedText(_ text: String, width: CGFloat) throws -> (
        geometry: MessageTextGeometry, metadata: MessageMetadata?,
        preparedText: MessageTextContent.PreparedText
    ) {
        let message = try TimelineTestFixtures.message(
            id: 1, senderID: 2, at: 0, hour: 12, minute: 34, fields: ["message": text])
        let row = TimelineRow.message(
            .init(
                entry: .remote(message), isOutgoing: false, groupPosition: .single,
                showsSenderName: false))
        let environment = TimelineLayoutEnvironment.current(
            timelineWidth: width + 24 + 2 * (36 + 8), bodySize: 14,
            timeZone: TimeZone(secondsFromGMT: 0)!)
        let presentation = TimelineRowPresentation.make(
            row: row, currentUserID: 1, isThreadTimeline: false,
            environment: environment)
        let layout = TimelineLayoutEngine().layout(presentation, environment: environment)
        return (
            try XCTUnwrap(layout.textGeometry), presentation.metadata,
            try XCTUnwrap(presentation.preparedText)
        )
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
