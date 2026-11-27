#if os(iOS)
    import ChahuaAPI
    import UIKit
    import XCTest

    @testable import chahua_apple

    @MainActor
    final class MessageInteractionIOSTests: XCTestCase {
        func testPagingUsesFixedPanelsAndSurvivesLiveUpdates() async throws {
            for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1194)] {
                for style in [UIUserInterfaceStyle.light, .dark] {
                    let message = try TimelineTestFixtures.message(
                        id: 1, senderID: 1, at: 0, text: "A published message",
                        fields: ["reactions": [["emoji": "👍", "count": 1, "reactedByMe": false]]])
                    let row = TimelineMessageRow(
                        entry: .remote(message), isOutgoing: true, groupPosition: .single,
                        showsSenderName: false)
                    let environment = TimelineLayoutEnvironment.current(
                        timelineWidth: size.width, isWideChatLayout: size.width >= 600)
                    let prepared = TimelineRowPresentation.make(
                        row: .message(row), currentUserID: 1, isThreadTimeline: false,
                        environment: environment)
                    let layout = TimelineLayoutEngine().layout(prepared, environment: environment)
                    var actions = TimelineBubbleActions()
                    actions.toggleReaction = { _, _ in }
                    var selectedActions: [MessageMenuAction] = []
                    var closeCount = 0
                    var value = MessageInteractionPresentation(
                        row: row, context: .init(canWrite: true, isAdmin: true, canSave: true),
                        currentUserID: 1,
                        source: .init(
                            rect: try XCTUnwrap(layout.frames[.bubble]).offsetBy(dx: 0, dy: 300),
                            presentation: prepared, layout: layout),
                        mediaContext: nil, actions: actions, interfaceStyle: style,
                        onEditPending: { _ in }, onRemovePending: { _ in }, isReacting: false,
                        onReaction: { _ in }, onAction: { selectedActions.append($0) },
                        onClose: { closeCount += 1 })
                    let scene = try XCTUnwrap(
                        UIApplication.shared.connectedScenes.first as? UIWindowScene)
                    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
                    let window = UIWindow(windowScene: scene)
                    window.overrideUserInterfaceStyle = style
                    let root = UIViewController()
                    root.view.backgroundColor = .systemGroupedBackground
                    window.rootViewController = root
                    window.makeKeyAndVisible()
                    window.frame = CGRect(origin: .zero, size: size)
                    XCTAssertEqual(window.bounds.size, size)
                    let original = TimelineRowView(
                        frame: CGRect(
                            x: 0, y: 300, width: layout.size.width, height: layout.size.height))
                    original.bind(
                        .init(
                            presentation: prepared, layout: layout,
                            context: .init(currentUserID: 1, isThreadTimeline: false),
                            actions: actions, mediaContext: nil))
                    root.view.addSubview(original)
                    original.layoutIfNeeded()
                    attachSurface(
                        window: window,
                        name: "\(Int(size.width))pt-\(style == .dark ? "dark" : "light")-original")
                    let controller = MessageInteractionViewController(
                        presentation: value, reduceMotion: false)
                    controller.loadViewIfNeeded()
                    controller.view.frame = window.bounds
                    controller.beginAppearanceTransition(true, animated: false)
                    window.addSubview(controller.view)
                    controller.endAppearanceTransition()
                    defer {
                        controller.cleanup()
                        controller.beginAppearanceTransition(false, animated: false)
                        controller.view.removeFromSuperview()
                        controller.endAppearanceTransition()
                        window.isHidden = true
                        window.rootViewController = nil
                        previousKeyWindow?.makeKey()
                    }
                    controller.mount(opacity: 1)
                    controller.enter()
                    try await Task.sleep(for: .milliseconds(300))
                    window.layoutIfNeeded()
                    controller.view.layoutIfNeeded()
                    let more = try XCTUnwrap(
                        buttons(in: controller.view).first {
                            $0.accessibilityIdentifier == "more-reactions"
                        })
                    XCTAssertEqual(more.bounds.width, 44, accuracy: 0.01)
                    XCTAssertEqual(more.bounds.height, 44, accuracy: 0.01)
                    try assertGridGeometry(in: controller.view)
                    try assertPreviewContour(original: original, controller: controller)
                    attachSurface(
                        window: window,
                        name: "\(Int(size.width))pt-\(style == .dark ? "dark" : "light")-page1")

                    let next = try XCTUnwrap(
                        buttons(in: controller.view).first {
                            $0.accessibilityIdentifier == "message-menu-page"
                        })
                    XCTAssertEqual(next.accessibilityLabel, AppLanguage.localized("More actions"))
                    next.sendActions(for: .touchUpInside)
                    XCTAssertEqual(closeCount, 0)
                    XCTAssertTrue(selectedActions.isEmpty)
                    controller.update(value)
                    let previous = try XCTUnwrap(
                        buttons(in: controller.view).first {
                            $0.accessibilityIdentifier == "message-menu-page"
                        })
                    XCTAssertEqual(
                        previous.accessibilityLabel, AppLanguage.localized("Previous actions"))
                    let recall = try XCTUnwrap(
                        buttons(in: controller.view).first {
                            $0.accessibilityLabel == MessageMenuAction.delete.label()
                        })
                    controller.view.layoutIfNeeded()
                    let recallLabel = try XCTUnwrap(recall.titleLabel)
                    XCTAssertLessThanOrEqual(
                        recallLabel.bounds.height, ceil(recallLabel.font.lineHeight) + 1)
                    try assertGridGeometry(in: controller.view)
                    try await Task.sleep(for: .milliseconds(30))
                    attachSurface(
                        window: window,
                        name: "\(Int(size.width))pt-\(style == .dark ? "dark" : "light")-page2")
                    let recallFrame = recall.convert(recall.bounds, to: controller.view)
                    XCTAssertTrue(
                        controller.view.bounds.insetBy(dx: 16, dy: 16).contains(recallFrame))
                    var ancestor = recall.superview
                    while let current = ancestor {
                        XCTAssertFalse(current is UIScrollView)
                        ancestor = current.superview
                    }

                    value = MessageInteractionPresentation(
                        row: value.row, context: .init(canWrite: true, canUseNetworkActions: false),
                        currentUserID: value.currentUserID, source: value.source,
                        mediaContext: nil, actions: actions, interfaceStyle: style,
                        onEditPending: value.onEditPending, onRemovePending: value.onRemovePending,
                        isReacting: false, onReaction: value.onReaction, onAction: value.onAction,
                        onClose: value.onClose)
                    controller.update(value)
                    XCTAssertFalse(
                        buttons(in: controller.view).contains {
                            $0.accessibilityIdentifier == "message-menu-page"
                        })
                    let copy = try XCTUnwrap(
                        buttons(in: controller.view).first {
                            $0.accessibilityLabel == MessageMenuAction.copy.label()
                        })
                    copy.sendActions(for: .touchUpInside)
                    XCTAssertEqual(closeCount, 1)
                    XCTAssertTrue(selectedActions.isEmpty)
                    let deferred = try XCTUnwrap(controller.takeDeferredAction())
                    deferred()
                    XCTAssertEqual(selectedActions, [.copy])
                }
            }
        }

        func testTallMessageStaysAtSourceAndPanelsFollowPress() {
            let bounds = CGRect(x: 0, y: 0, width: 390, height: 700)
            let source = CGRect(x: 40, y: -120, width: 300, height: 1000)
            let first = MessageOverlayLayout(
                bounds: bounds, source: source, previewSize: source.size,
                controlsWidth: 276, reactionHeight: 56, actionsHeight: 138,
                isOutgoing: false, pressPoint: CGPoint(x: 100, y: 200))
            let second = MessageOverlayLayout(
                bounds: bounds, source: source, previewSize: source.size,
                controlsWidth: 276, reactionHeight: 56, actionsHeight: 138,
                isOutgoing: false, pressPoint: CGPoint(x: 100, y: 500))
            XCTAssertEqual(first.previewFrame, source)
            XCTAssertEqual(second.previewFrame, source)
            XCTAssertEqual(first.reactionFrame.maxY, 192)
            XCTAssertEqual(first.actionsFrame.minY, 208)
            XCTAssertGreaterThan(second.actionsFrame.minY, first.actionsFrame.minY)
            XCTAssertTrue(bounds.insetBy(dx: 16, dy: 16).contains(second.actionsFrame))
        }

        func testFittingStackShiftsTogetherAndKeepsEightPointGaps() {
            let placement = MessageOverlayLayout(
                bounds: CGRect(x: 0, y: 0, width: 390, height: 700),
                source: CGRect(x: 110, y: 620, width: 250, height: 60),
                previewSize: CGSize(width: 250, height: 60), controlsWidth: 276,
                reactionHeight: 56, actionsHeight: 138, isOutgoing: true)
            XCTAssertEqual(placement.previewFrame.minY - placement.reactionFrame.maxY, 8)
            XCTAssertEqual(placement.actionsFrame.minY - placement.previewFrame.maxY, 8)
            XCTAssertEqual(placement.actionsFrame.maxY, 684)
            XCTAssertEqual(placement.actionsFrame.maxX, placement.previewFrame.maxX)
        }

        func testPreviewPreservesNativeContourAcrossGroupingAndDirection() throws {
            let message = try TimelineTestFixtures.message(
                id: 1, senderID: 1, at: 0, text: "A published message")
            for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1194)] {
                for style in [UIUserInterfaceStyle.light, .dark] {
                    for outgoing in [false, true] {
                        for position in [
                            TimelineGroupPosition.single, .first, .middle, .last,
                        ] {
                            let row = TimelineMessageRow(
                                entry: .remote(message), isOutgoing: outgoing,
                                groupPosition: position, showsSenderName: false)
                            let environment = TimelineLayoutEnvironment.current(
                                timelineWidth: size.width, isWideChatLayout: size.width >= 600)
                            let prepared = TimelineRowPresentation.make(
                                row: .message(row), currentUserID: 1, isThreadTimeline: false,
                                environment: environment)
                            let layout = TimelineLayoutEngine().layout(
                                prepared, environment: environment)
                            let original = TimelineRowView(
                                frame: CGRect(origin: .zero, size: layout.size))
                            original.overrideUserInterfaceStyle = style
                            original.bind(
                                .init(
                                    presentation: prepared, layout: layout,
                                    context: .init(currentUserID: 1, isThreadTimeline: false),
                                    actions: .init(), mediaContext: nil))
                            original.layoutIfNeeded()
                            let bubble = try XCTUnwrap(layout.frames[.bubble])
                            let controller = MessageInteractionViewController(
                                presentation: .init(
                                    row: row, context: .init(canWrite: true), currentUserID: 1,
                                    source: .init(
                                        rect: bubble.offsetBy(dx: 0, dy: 300),
                                        presentation: prepared, layout: layout),
                                    mediaContext: nil, actions: .init(), interfaceStyle: style,
                                    onEditPending: { _ in }, onRemovePending: { _ in },
                                    isReacting: false, onReaction: { _ in }, onAction: { _ in },
                                    onClose: {}),
                                reduceMotion: true)
                            controller.loadViewIfNeeded()
                            controller.view.frame = CGRect(origin: .zero, size: size)
                            controller.mount(opacity: 1)
                            controller.view.layoutIfNeeded()
                            try assertPreviewContour(original: original, controller: controller)
                            controller.view.frame.size.width = 120
                            controller.view.setNeedsLayout()
                            controller.view.layoutIfNeeded()
                            try assertPreviewContour(original: original, controller: controller)
                            controller.cleanup()
                        }
                    }
                }
            }
        }

        private func descendants<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
            (view as? T).map { [$0] }
                ?? view.subviews.flatMap { descendants(of: type, in: $0) }
        }

        private func assertGridGeometry(
            in view: UIView, file: StaticString = #filePath, line: UInt = #line
        ) throws {
            let grid = descendants(of: MessageInteractionButton.self, in: view)
                .filter(\.isGridAction)
            XCTAssertFalse(grid.isEmpty, file: file, line: line)
            for button in grid {
                button.layoutIfNeeded()
                let imageView = try XCTUnwrap(button.imageView, file: file, line: line)
                let image = try XCTUnwrap(imageView.image, file: file, line: line)
                let hasTitle = button.currentTitle != nil
                let groupHeight: CGFloat = hasTitle ? 42 : 23
                let box = CGRect(
                    x: button.bounds.midX - 11.5,
                    y: button.bounds.midY - groupHeight / 2, width: 23, height: 23)
                XCTAssertEqual(button.bounds.height, 63, accuracy: 0.01, file: file, line: line)
                XCTAssertTrue(
                    box.insetBy(dx: -0.01, dy: -0.01).contains(imageView.frame),
                    "Glyph must fit its icon box: \(button.accessibilityLabel ?? "")",
                    file: file, line: line)
                XCTAssertEqual(
                    max(imageView.bounds.width, imageView.bounds.height), 23, accuracy: 0.01,
                    file: file, line: line)
                XCTAssertEqual(
                    imageView.bounds.width / imageView.bounds.height,
                    image.size.width / image.size.height, accuracy: 0.001, file: file, line: line)
                XCTAssertEqual(
                    imageView.frame.midX, box.midX, accuracy: 0.01, file: file, line: line)
                XCTAssertEqual(
                    imageView.frame.midY, box.midY, accuracy: 0.01, file: file, line: line)
                if hasTitle {
                    let label = try XCTUnwrap(button.titleLabel, file: file, line: line)
                    XCTAssertEqual(
                        label.frame.minY - box.maxY, 7, accuracy: 0.01, file: file, line: line)
                    XCTAssertEqual(
                        label.bounds.height, 12, accuracy: 0.01, file: file, line: line)
                    XCTAssertEqual(label.numberOfLines, 1, file: file, line: line)
                    XCTAssertTrue(label.adjustsFontSizeToFitWidth, file: file, line: line)
                }
                XCTAssertTrue(
                    button.isAccessibilityElement,
                    "Action must be accessible: \(button.accessibilityLabel ?? "")",
                    file: file, line: line)
                XCTAssertTrue(
                    button.accessibilityTraits.contains(.button),
                    "Action must expose button activation: \(button.accessibilityLabel ?? "")",
                    file: file, line: line)
            }
        }

        private func assertPreviewContour(
            original: TimelineRowView, controller: MessageInteractionViewController,
            file: StaticString = #filePath, line: UInt = #line
        ) throws {
            let sourceBubble = try XCTUnwrap(
                descendants(of: TimelineBubbleContentView.self, in: original).first,
                file: file, line: line)
            let previewRow = try XCTUnwrap(
                descendants(of: TimelineRowView.self, in: controller.view).first,
                file: file, line: line)
            let previewBubble = try XCTUnwrap(
                descendants(of: TimelineBubbleContentView.self, in: previewRow).first,
                file: file, line: line)
            let clip = try XCTUnwrap(previewRow.superview, file: file, line: line)
            sourceBubble.layoutIfNeeded()
            previewRow.layoutIfNeeded()
            previewBubble.layoutIfNeeded()
            XCTAssertEqual(previewBubble.bounds, sourceBubble.bounds, file: file, line: line)
            XCTAssertEqual(
                previewRow.binding?.layout.frames, original.binding?.layout.frames,
                file: file, line: line)
            let sourceSurface = try XCTUnwrap(
                sourceBubble.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first,
                file: file, line: line)
            let previewSurface = try XCTUnwrap(
                previewBubble.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first,
                file: file, line: line)
            let sourcePath = try XCTUnwrap(sourceSurface.path, file: file, line: line)
            let previewPath = try XCTUnwrap(previewSurface.path, file: file, line: line)
            XCTAssertTrue(sourcePath == previewPath, file: file, line: line)
            let maskView =
                clip.bounds.size == sourceBubble.bounds.size ? clip : previewBubble
            XCTAssertEqual(
                alphaMask(of: sourceBubble), alphaMask(of: maskView), file: file, line: line)
            for point in [
                CGPoint(
                    x: sourcePath.boundingBoxOfPath.maxX - 0.5, y: sourceBubble.bounds.maxY - 1),
                CGPoint(
                    x: sourcePath.boundingBoxOfPath.minX + 0.5, y: sourceBubble.bounds.maxY - 1),
            ] where sourcePath.contains(point) {
                var ancestor: UIView? = previewBubble
                while let current = ancestor, current !== controller.view {
                    if current.clipsToBounds {
                        XCTAssertTrue(
                            current.bounds.contains(current.convert(point, from: previewBubble)),
                            file: file, line: line)
                    }
                    ancestor = current.superview
                }
            }
        }

        private func alphaMask(of view: UIView) -> [UInt8] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let image = UIGraphicsImageRenderer(
                size: CGSize(width: view.bounds.width + 20, height: view.bounds.height + 20),
                format: format
            ).image { context in
                context.cgContext.translateBy(x: 10, y: 10)
                view.layer.render(in: context.cgContext)
            }
            guard let cgImage = image.cgImage else { return [] }
            let width = cgImage.width
            let height = cgImage.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                guard
                    let context = CGContext(
                        data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        }

        private func attachSurface(window: UIWindow, name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        private func buttons(in view: UIView) -> [UIButton] {
            (view as? UIButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
    }
#endif
