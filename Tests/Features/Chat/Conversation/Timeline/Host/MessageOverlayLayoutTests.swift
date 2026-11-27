#if os(macOS)
    import AppKit
    import ChahuaAPI
    import SwiftUI
    import XCTest
    @testable import chahua_apple

    @MainActor
    final class MessageOverlayLayoutTests: XCTestCase {
        func testImageViewerBlocksMessageContextClicksUntilDismissed() async throws {
            let previousTickSource = TimelineDisplayScheduler.tickSource
            TimelineDisplayScheduler.tickSource = .runLoop
            defer { TimelineDisplayScheduler.tickSource = previousTickSource }
            let message = try TimelineTestFixtures.message(
                id: 1, senderID: 2, at: 0, text: "The original message behind the viewer")
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: true,
                source: OverlayPageSource(page: try TimelineTestFixtures.page([message])),
                messageStore: ConversationMessageStore())
            await model.loadInitial()
            let host = NSHostingController(
                rootView: ConversationTimelineView(
                    model: model, loadsInitialAutomatically: false,
                    interactionContext: .init(canWrite: true, isAdmin: true)
                ).modifier(TimelineInteractionOverlayRoot()))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(CGSize(width: 800, height: 600))
            host.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            window.makeKeyAndOrderFront(nil)
            defer {
                window.contentViewController = nil
                window.close()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while textViews(in: host.view).isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                host.view.layoutSubtreeIfNeeded()
            }
            let text = try XCTUnwrap(textViews(in: host.view).first)
            let clickPoint = text.convert(
                CGPoint(x: text.bounds.midX, y: text.bounds.midY), to: nil)
            let gallery = try XCTUnwrap(
                MessageImageGallery(
                    messageID: "image",
                    items: [
                        .init(
                            id: "image", url: nil, contentType: "image/png",
                            fileName: "image.png", width: 16, height: 16)
                    ],
                    selectedID: "image"))
            let viewer = MessageImageDetailMacView(
                gallery: gallery, mediaContext: nil, onDismiss: {})
            viewer.frame = host.view.bounds
            host.view.addSubview(viewer)
            viewer.layoutSubtreeIfNeeded()
            defer { viewer.invalidate() }
            func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws {
                let event = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: clickPoint, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1))
                NSApp.postEvent(event, atStart: false)
            }
            let frame = try XCTUnwrap(window.contentView?.superview)
            let copyLabel = MessageMenuAction.copy.label()
            for (type, modifiers) in [
                (NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()),
                (.leftMouseDown, .control),
            ] {
                try click(type, modifiers: modifiers)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(buttons(in: frame).contains { $0.accessibilityLabel() == copyLabel })
            }
            viewer.invalidate()
            viewer.removeFromSuperview()
            try click(.rightMouseDown)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(buttons(in: frame).contains { $0.accessibilityLabel() == copyLabel })
        }

        func testMenuLiftsCapturedMessageWithoutReparentingAndDismissesOnOutsideClick() async throws
        {
            let previousTickSource = TimelineDisplayScheduler.tickSource
            TimelineDisplayScheduler.tickSource = .runLoop
            defer { TimelineDisplayScheduler.tickSource = previousTickSource }
            for (outgoing, dark, width, height, hasWindowChrome) in [
                (false, false, 900.0, 650.0, true), (true, true, 900.0, 650.0, true),
                (true, false, 900.0, 650.0, true),
                (false, false, 360.0, 650.0, true), (false, false, 560.0, 650.0, false),
                (false, false, 320.0, 300.0, false),
            ] {
                let message = try TimelineTestFixtures.message(
                    id: 1, senderID: outgoing ? 1 : 2, at: 0,
                    text:
                        "The original message keeps its full width. Model: DeepSeek-V4.1-Flash-Expires-On-0910. Reactions and actions remain in a compact, matte menu."
                )
                let source = OverlayPageSource(page: try TimelineTestFixtures.page([message]))
                let model = ConversationTimelineModel(
                    chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
                    messageStore: ConversationMessageStore())
                await model.loadInitial()
                let timeline = ConversationTimelineView(
                    model: model, loadsInitialAutomatically: false,
                    interactionContext: .init(canWrite: true, isAdmin: true)
                )
                .preferredColorScheme(dark ? .dark : .light)
                let host = NSHostingController(
                    rootView: Group {
                        if hasWindowChrome {
                            timeline.modifier(MacConversationWindowChrome())
                        } else {
                            timeline.modifier(TimelineInteractionOverlayRoot())
                        }
                    })
                let size = CGSize(width: width, height: height)
                let window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable], backing: .buffered,
                    defer: false)
                window.animationBehavior = .none
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentViewController = host
                window.setContentSize(size)
                host.view.frame = CGRect(origin: .zero, size: size)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                defer {
                    window.contentViewController = nil
                    window.close()
                }
                host.view.layoutSubtreeIfNeeded()
                let loadDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                while textViews(in: host.view).isEmpty, ContinuousClock.now < loadDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                    host.view.layoutSubtreeIfNeeded()
                }
                let original = try XCTUnwrap(textViews(in: host.view).first)
                let frameView = try XCTUnwrap(window.contentView?.superview)
                let originalFrame = original.convert(original.bounds, to: frameView)
                var ancestor: NSView? = original
                while ancestor != nil, !(ancestor is TimelineRowView) {
                    ancestor = ancestor?.superview
                }
                let row = try XCTUnwrap(ancestor as? TimelineRowView)
                let bubbleRect = try XCTUnwrap(row.binding?.layout.frames[.bubble])
                let sourceContour = try XCTUnwrap(
                    row.interactionContour?.normalized(using: .winding))
                let bodyBounds = CGRect(origin: .zero, size: bubbleRect.size)
                let captureBounds = bodyBounds.union(sourceContour.boundingBoxOfPath).integral
                XCTAssertFalse(
                    bodyBounds.contains(sourceContour.boundingBoxOfPath),
                    "The existing single-message fixture must exercise a native outward tail.")
                let originalCaptureRect = row.convert(
                    captureBounds.offsetBy(dx: bubbleRect.minX, dy: bubbleRect.minY), to: frameView)
                let originalBitmap = try XCTUnwrap(
                    frameView.bitmapImageRepForCachingDisplay(in: originalCaptureRect))
                frameView.cacheDisplay(in: originalCaptureRect, to: originalBitmap)
                let originalAttachment = XCTAttachment(
                    data: try XCTUnwrap(
                        originalBitmap.representation(using: .png, properties: [:])),
                    uniformTypeIdentifier: "public.png")
                originalAttachment.name =
                    "Native source with \(outgoing ? "outgoing" : "incoming") tail \(Int(width))"
                originalAttachment.lifetime = .keepAlways
                add(originalAttachment)
                let action = try XCTUnwrap(row.accessibilityCustomActions()?.first)
                XCTAssertTrue(try XCTUnwrap(action.handler)())
                let copyLabel = MessageMenuAction.copy.label()
                frameView.layoutSubtreeIfNeeded()
                let copyAction = try XCTUnwrap(
                    buttons(in: frameView).first { $0.accessibilityLabel() == copyLabel },
                    "Missing Copy action: outgoing=\(outgoing), dark=\(dark), width=\(width)")
                let actionSurface = try XCTUnwrap(copyAction.superview)
                let surfaceLayer = try XCTUnwrap(actionSurface.layer)
                XCTAssertTrue(
                    surfaceLayer.masksToBounds,
                    "The matte action backing must not escape the rounded rim.")
                XCTAssertEqual(surfaceLayer.cornerRadius, MessageMenuLayout.radius)
                XCTAssertEqual(surfaceLayer.cornerCurve, .continuous)
                XCTAssertFalse(actionSurface.subviews.contains { $0 is NSVisualEffectView })
                if #available(macOS 26, *) {
                    XCTAssertFalse(actionSurface.subviews.contains { $0 is NSGlassEffectView })
                }
                let actionPanel = try XCTUnwrap(actionSurface.superview)
                let overlay = try XCTUnwrap(actionOverlay(in: frameView))
                XCTAssertFalse(
                    containsScrollView(in: overlay),
                    "Quick actions and reactions must use fixed panels, never scrolling.")
                let shadowPath = try XCTUnwrap(actionPanel.layer?.shadowPath)
                // Native layer backing can quantize fractional layout bounds.
                // Keep the visible silhouette aligned within one physical pixel.
                let shadowBounds = shadowPath.boundingBoxOfPath
                let pixel = 1 / window.backingScaleFactor
                for (actual, expected) in [
                    (shadowBounds.minX, actionPanel.bounds.minX),
                    (shadowBounds.maxX, actionPanel.bounds.maxX),
                    (shadowBounds.minY, actionPanel.bounds.minY),
                    (shadowBounds.maxY, actionPanel.bounds.maxY),
                ] {
                    XCTAssertEqual(actual, expected, accuracy: pixel)
                }
                for x in [actionPanel.bounds.minX + 0.5, actionPanel.bounds.maxX - 0.5] {
                    for y in [actionPanel.bounds.minY + 0.5, actionPanel.bounds.maxY - 0.5] {
                        XCTAssertFalse(
                            shadowPath.contains(CGPoint(x: x, y: y)),
                            "Rounded menu corners must not cast a rectangular backing shadow.")
                    }
                }
                XCTAssertTrue(
                    shadowPath.contains(
                        CGPoint(x: actionPanel.bounds.midX, y: actionPanel.bounds.midY)))
                // Capture the settled native presentation, not the lift animation.
                try await Task.sleep(for: .milliseconds(220))
                let menuCaptureRect = frameView.bounds
                let menuBitmap = try XCTUnwrap(
                    frameView.bitmapImageRepForCachingDisplay(in: menuCaptureRect))
                frameView.cacheDisplay(in: menuCaptureRect, to: menuBitmap)
                let menuAttachment = XCTAttachment(
                    data: try XCTUnwrap(menuBitmap.representation(using: .png, properties: [:])),
                    uniformTypeIdentifier: "public.png")
                menuAttachment.name =
                    "Message popup \(dark ? "dark" : "light") \(Int(width))x\(Int(height))"
                menuAttachment.lifetime = .keepAlways
                add(menuAttachment)
                XCTAssertEqual(
                    textViews(in: frameView).count, 1,
                    "A captured preview must not duplicate live text-selection controls.")
                XCTAssertEqual(
                    original.convert(original.bounds, to: frameView), originalFrame,
                    "Opening the menu must not move or resize the message.")
                let lifted = try XCTUnwrap(
                    overlay.subviews.flatMap(\.subviews).compactMap { $0 as? NSImageView }
                        .first { $0.layer?.mask is CAShapeLayer })
                XCTAssertNotNil(
                    lifted.image, "The lifted preview must preserve the native capture.")
                let mask = try XCTUnwrap(lifted.layer?.mask as? CAShapeLayer)
                let sourceRect = overlay.convert(bubbleRect, from: row)
                XCTAssertEqual(lifted.frame.size, captureBounds.size)
                XCTAssertEqual(lifted.image?.size, captureBounds.size)
                var contourTransform = CGAffineTransform(
                    translationX: -captureBounds.minX, y: -captureBounds.minY)
                XCTAssertEqual(mask.path, sourceContour.copy(using: &contourTransform))
                let maskBounds = try XCTUnwrap(mask.path).boundingBoxOfPath
                XCTAssertTrue(
                    lifted.bounds.contains(maskBounds),
                    "Capture \(lifted.bounds) must contain the complete native contour \(maskBounds)."
                )
                let liftedBody = CGRect(
                    x: lifted.frame.minX - captureBounds.minX,
                    y: lifted.frame.minY - captureBounds.minY,
                    width: bodyBounds.width, height: bodyBounds.height)
                XCTAssertTrue(
                    lifted.isFlipped,
                    "The image and exact source contour must both use top-origin coordinates.")
                XCTAssertEqual(mask.frame, lifted.bounds)
                XCTAssertEqual(mask.bounds, CGRect(origin: .zero, size: lifted.bounds.size))
                let withoutPreview = try XCTUnwrap(
                    frameView.bitmapImageRepForCachingDisplay(in: menuCaptureRect))
                lifted.isHidden = true
                frameView.cacheDisplay(in: menuCaptureRect, to: withoutPreview)
                lifted.isHidden = false
                let contour = try XCTUnwrap(mask.path)
                let scaleX = CGFloat(menuBitmap.pixelsWide) / menuCaptureRect.width
                let scaleY = CGFloat(menuBitmap.pixelsHigh) / menuCaptureRect.height
                var checkedCornerPixels = 0
                var maximumCornerDifference = CGFloat(0)
                for cornerX in [CGFloat(0), lifted.bounds.width - 18] {
                    for cornerY in [CGFloat(0), lifted.bounds.height - 18] {
                        for dx in stride(from: CGFloat(1.5), through: 16, by: 2) {
                            for dy in stride(from: CGFloat(1.5), through: 16, by: 2) {
                                let point = CGPoint(x: cornerX + dx, y: cornerY + dy)
                                // Stay clear of the antialiased contour edge.
                                let touchesBubble = [CGFloat(-1), 0, 1].contains { x in
                                    [CGFloat(-1), 0, 1].contains { y in
                                        contour.contains(
                                            CGPoint(x: point.x + x, y: point.y + y))
                                    }
                                }
                                guard !touchesBubble else { continue }
                                let inFrame = lifted.convert(point, to: frameView)
                                let px = Int((inFrame.x - menuCaptureRect.minX) * scaleX)
                                let topY =
                                    frameView.isFlipped
                                    ? inFrame.y - menuCaptureRect.minY
                                    : menuCaptureRect.maxY - inFrame.y
                                let py = Int(topY * scaleY)
                                guard px >= 0, py >= 0, px < menuBitmap.pixelsWide,
                                    py < menuBitmap.pixelsHigh
                                else { continue }
                                let actual = try XCTUnwrap(
                                    menuBitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB))
                                let background = try XCTUnwrap(
                                    withoutPreview.colorAt(x: px, y: py)?.usingColorSpace(
                                        .deviceRGB))
                                maximumCornerDifference = max(
                                    maximumCornerDifference,
                                    abs(actual.redComponent - background.redComponent),
                                    abs(actual.greenComponent - background.greenComponent),
                                    abs(actual.blueComponent - background.blueComponent))
                                checkedCornerPixels += 1
                            }
                        }
                    }
                }
                XCTAssertGreaterThan(
                    checkedCornerPixels, 0,
                    "Rounded lifted corners must expose the backdrop, not source timeline pixels.")
                XCTAssertLessThanOrEqual(
                    maximumCornerDifference, 0.03,
                    "Non-bubble timeline pixels must not leak through any lifted rounded corner.")
                let more = try XCTUnwrap(
                    buttons(in: overlay).first {
                        $0.accessibilityLabel() == AppLanguage.localized("More reactions")
                    })
                let reactions = try XCTUnwrap(more.superview)
                XCTAssertEqual(reactions.frame.width, MessageMenuLayout.width)
                XCTAssertEqual(reactions.frame.height, MessageMenuLayout.reactionHeight)
                let stackHeight =
                    reactions.frame.height + sourceRect.height
                    + actionPanel.frame.height + MessageMenuLayout.gap * 2
                if stackHeight <= overlay.bounds.height - 32 {
                    let sourceTailPoint = CGPoint(
                        x: outgoing ? bodyBounds.maxX + 2 : -2, y: bodyBounds.maxY - 2)
                    XCTAssertTrue(sourceContour.contains(sourceTailPoint))
                    let tailPoint = CGPoint(
                        x: sourceTailPoint.x - captureBounds.minX,
                        y: sourceTailPoint.y - captureBounds.minY)
                    let inFrame = lifted.convert(tailPoint, to: frameView)
                    let px = Int((inFrame.x - menuCaptureRect.minX) * scaleX)
                    let py = Int(
                        (frameView.isFlipped
                            ? inFrame.y - menuCaptureRect.minY
                            : menuCaptureRect.maxY - inFrame.y) * scaleY)
                    let sourceX = Int(
                        tailPoint.x * CGFloat(originalBitmap.pixelsWide) / captureBounds.width)
                    let sourceY = Int(
                        tailPoint.y * CGFloat(originalBitmap.pixelsHigh) / captureBounds.height)
                    let tailColor = try XCTUnwrap(
                        menuBitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB))
                    let originalTailColor = try XCTUnwrap(
                        originalBitmap.colorAt(x: sourceX, y: sourceY)?.usingColorSpace(.deviceRGB))
                    let background = try XCTUnwrap(
                        withoutPreview.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(
                        tailColor.redComponent, originalTailColor.redComponent, accuracy: 0.03)
                    XCTAssertEqual(
                        tailColor.greenComponent, originalTailColor.greenComponent, accuracy: 0.03)
                    XCTAssertEqual(
                        tailColor.blueComponent, originalTailColor.blueComponent, accuracy: 0.03)
                    XCTAssertGreaterThan(
                        max(
                            abs(tailColor.redComponent - background.redComponent),
                            abs(tailColor.greenComponent - background.greenComponent),
                            abs(tailColor.blueComponent - background.blueComponent)),
                        0.08,
                        "The outward native tail must remain visible, not be clipped to the body.")
                    XCTAssertEqual(reactions.frame.maxY + MessageMenuLayout.gap, liftedBody.minY)
                    XCTAssertEqual(
                        liftedBody.maxY + MessageMenuLayout.gap, actionPanel.frame.minY)
                } else {
                    XCTAssertEqual(liftedBody.minY, sourceRect.minY)
                    XCTAssertTrue(overlay.bounds.contains(reactions.frame))
                    XCTAssertTrue(overlay.bounds.contains(actionPanel.frame))
                }
                let captureRect = lifted.convert(
                    lifted.bounds.insetBy(dx: -12, dy: -12), to: frameView)
                let bitmap = try XCTUnwrap(
                    frameView.bitmapImageRepForCachingDisplay(in: captureRect))
                frameView.cacheDisplay(in: captureRect, to: bitmap)
                let attachment = XCTAttachment(
                    data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                    uniformTypeIdentifier: "public.png")
                attachment.name =
                    "Selected \(outgoing ? "outgoing" : "incoming") bubble \(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertTrue(copyAction.isEnabled)
                // The supported content hierarchy must receive clicks on menu actions.
                let content = try XCTUnwrap(window.contentView)
                let copyPoint = copyAction.convert(
                    CGPoint(x: copyAction.bounds.midX, y: copyAction.bounds.midY),
                    to: content.superview)
                let hit = content.hitTest(copyPoint)
                XCTAssertTrue(hit === copyAction || hit?.isDescendant(of: copyAction) == true)

                // A click over native title-bar chrome dismisses the menu,
                // without also activating the close button.
                let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
                let titleBarPoint = closeButton.convert(
                    CGPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let click = try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: type, location: titleBarPoint, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber,
                            context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
                    NSApp.postEvent(click, atStart: false)
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while buttons(in: frameView).contains(where: {
                    $0.accessibilityLabel() == copyLabel
                }), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(
                    window.isVisible, "The outside click must not activate the window control.")
                XCTAssertFalse(
                    buttons(in: frameView).contains {
                        $0.accessibilityLabel() == copyLabel
                    }, "Clicking title-bar chrome must dismiss the menu.")
            }
        }

        func testPagingStaysOpenAndPreservesPageDuringLiveSavedStateUpdate() async throws {
            let message = try TimelineTestFixtures.message(
                id: 1, senderID: 1, at: 0, text: "Pageable message",
                fields: ["reactions": [["emoji": "👍", "count": 1, "reactedByMe": false]]])
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: true,
                source: OverlayPageSource(page: try TimelineTestFixtures.page([message])),
                messageStore: ConversationMessageStore())
            await model.loadInitial()
            let row = try XCTUnwrap(
                model.rows.compactMap { item -> TimelineMessageRow? in
                    if case .message(let row) = item { return row }
                    return nil
                }.first)
            let overlay = TimelineActionOverlayView(
                frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            defer { overlay.clear() }
            var context = MessageInteractionContext(canWrite: true, isAdmin: true, canSave: true)
            var actions = TimelineBubbleActions()
            actions.replyToMessage = { _ in }
            actions.openThread = { _ in }
            actions.editMessage = { _ in }
            actions.deleteMessage = { _ in }
            actions.togglePin = { _ in }
            actions.toggleSavedMessage = { _ in }
            actions.toggleMessageSelection = { _ in }
            actions.forwardMessage = { _ in }
            actions.openReactionDetails = { _ in }
            var dismissals = 0
            var performed: [MessageMenuAction] = []
            overlay.onDismiss = { dismissals += 1 }
            overlay.onAction = { performed.append($0) }
            let rect = CGRect(x: 100, y: 180, width: 220, height: 64)
            let contour = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
            func update() {
                overlay.configure(
                    row: row, context: context, actions: actions,
                    sourceRect: rect, sourceContour: contour)
            }
            update()
            let next = try XCTUnwrap(
                buttons(in: overlay).first {
                    !$0.isHidden && $0.accessibilityLabel() == AppLanguage.localized("More actions")
                })
            let padding = MessageMenuLayout.padding
            let cellWidth = (MessageMenuLayout.width - padding * 2) / 5
            let firstPageGlyphs = try assertActionGlyphsPreserveProportions(in: overlay, page: 0)
            XCTAssertEqual(next.frame.minX, padding + 4 * cellWidth)
            XCTAssertEqual(next.frame.minY, padding + MessageMenuLayout.rowHeight)
            next.performClick(nil)
            let secondPageGlyphs = try assertActionGlyphsPreserveProportions(in: overlay, page: 1)
            XCTAssertEqual(
                firstPageGlyphs.union(secondPageGlyphs),
                Set([MessageMenuAction.thread.label(), MessageMenuAction.reactionDetails.label()]))
            XCTAssertEqual(next.frame.minX, padding + 4 * cellWidth)
            XCTAssertEqual(next.frame.minY, padding)
            XCTAssertEqual(dismissals, 0)
            XCTAssertTrue(performed.isEmpty)
            XCTAssertTrue(
                buttons(in: overlay).contains {
                    !$0.isHidden && $0.accessibilityLabel() == MessageMenuAction.delete.label()
                })
            context.isSaved = true
            update()
            XCTAssertTrue(
                buttons(in: overlay).contains {
                    !$0.isHidden
                        && $0.accessibilityLabel() == AppLanguage.localized("Previous actions")
                })
            let unsave = try XCTUnwrap(
                buttons(in: overlay).first {
                    !$0.isHidden
                        && $0.accessibilityLabel() == MessageMenuAction.save.label(isSaved: true)
                })
            XCTAssertEqual(unsave.accessibilityValue() as? Int, 1)
            XCTAssertFalse(containsScrollView(in: overlay))
        }

        private func assertActionGlyphsPreserveProportions(
            in overlay: TimelineActionOverlayView, page: Int
        ) throws -> Set<String> {
            var rendered = Set<String>()
            for action in [MessageMenuAction.thread, .reactionDetails] {
                guard
                    let button = buttons(in: overlay).first(where: {
                        !$0.isHidden && $0.accessibilityLabel() == action.label()
                    })
                else { continue }
                let image = try XCTUnwrap(
                    NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(
                            .init(pointSize: MessageMenuLayout.actionIcon, weight: .regular))?
                        .withSymbolConfiguration(.init(paletteColors: [.black])))
                XCTAssertGreaterThan(
                    abs(image.size.width - image.size.height), 1,
                    "This regression must exercise a non-square SF Symbol.")
                let icon = MessageMenuLayout.actionIcon
                let top =
                    (button.bounds.height - icon - MessageMenuLayout.labelGap
                        - MessageMenuLayout.labelLineHeight) / 2
                let box = CGRect(
                    x: (button.bounds.width - icon) / 2, y: top, width: icon, height: icon)
                let actual = try rasterize(size: button.bounds.size) {
                    button.draw(button.bounds)
                }
                let expected = try rasterize(size: button.bounds.size) {
                    let scale = icon / max(image.size.width, image.size.height)
                    let size = CGSize(
                        width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(
                        in: CGRect(
                            x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                            width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                        hints: nil)
                }
                let actualBounds = try XCTUnwrap(opaqueBounds(in: actual, within: box))
                let expectedBounds = try XCTUnwrap(opaqueBounds(in: expected, within: box))
                XCTAssertEqual(actualBounds.width, expectedBounds.width, accuracy: 1)
                XCTAssertEqual(actualBounds.height, expectedBounds.height, accuracy: 1)
                XCTAssertEqual(actualBounds.midX, expectedBounds.midX, accuracy: 1)
                XCTAssertEqual(actualBounds.midY, expectedBounds.midY, accuracy: 1)
                let attachment = XCTAttachment(
                    data: try XCTUnwrap(actual.representation(using: .png, properties: [:])),
                    uniformTypeIdentifier: "public.png")
                attachment.name = "Native \(action.label()) glyph page \(page)"
                attachment.lifetime = .keepAlways
                add(attachment)
                rendered.insert(action.label())
            }
            return rendered
        }

        private func rasterize(size: CGSize, draw: () -> Void) throws -> NSBitmapImageRep {
            let scale = CGFloat(4)
            let bitmap = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                    pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            context.cgContext.clear(
                CGRect(
                    x: 0, y: 0, width: CGFloat(bitmap.pixelsWide),
                    height: CGFloat(bitmap.pixelsHigh)))
            context.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
            context.cgContext.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(
                cgContext: context.cgContext, flipped: true)
            draw()
            context.cgContext.flush()
            return bitmap
        }

        private func opaqueBounds(in bitmap: NSBitmapImageRep, within box: CGRect) -> CGRect? {
            let scale = CGFloat(4)
            var bounds = CGRect.null
            for y in Int(floor(box.minY * scale))..<Int(ceil(box.maxY * scale)) {
                for x in Int(floor(box.minX * scale))..<Int(ceil(box.maxX * scale))
                where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    bounds = bounds.union(
                        CGRect(
                            x: CGFloat(x) / scale, y: CGFloat(y) / scale,
                            width: 1 / scale, height: 1 / scale))
                }
            }
            return bounds.isNull ? nil : bounds
        }

        private func actionOverlay(in view: NSView) -> TimelineActionOverlayView? {
            (view as? TimelineActionOverlayView)
                ?? view.subviews.lazy.compactMap { self.actionOverlay(in: $0) }.first
        }

        private func containsScrollView(in view: NSView) -> Bool {
            view is NSScrollView || view.subviews.contains { containsScrollView(in: $0) }
        }

        private func textViews(in view: NSView) -> [AppKitMessageTextView] {
            if let text = view as? AppKitMessageTextView,
                text.string.contains("The original message")
            {
                return [text]
            }
            return view.subviews.flatMap { textViews(in: $0) }
        }

        private func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
    }

    @MainActor
    private final class OverlayPageSource: TimelineMessageSource {
        let page: ListMessagesResponse
        init(page: ListMessagesResponse) { self.page = page }
        func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> TimelinePage {
            TimelinePage(response: page)
        }
    }
#endif
