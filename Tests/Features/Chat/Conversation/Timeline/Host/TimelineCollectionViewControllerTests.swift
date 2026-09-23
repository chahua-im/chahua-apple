#if os(iOS)
    import ChahuaAPI
    import Combine
    import UIKit
    import XCTest
    import SwiftUI
    @testable import chahua_apple

    @MainActor
    final class TimelineCollectionViewControllerTests: XCTestCase {

        func testDeletionRemovesNativeRowsAndEmptyDateSeparators() async throws {
            let messages = try [
                TimelineTestFixtures.message(id: "first", at: 0),
                TimelineTestFixtures.message(id: "second", at: 86_400),
            ]
            let store = ConversationMessageStore()
            let source = BubbleSource(page: try TimelineTestFixtures.page(messages))
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: true,
                source: source, messageStore: store)
            let controller = TimelineCollectionViewController(model: model, actions: .init())
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                model.close()
            }
            await model.loadInitial()
            try await Task.sleep(for: .milliseconds(100))
            let collection = try XCTUnwrap(
                controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            XCTAssertEqual(collection.numberOfItems(inSection: 0), 4)

            store.apply(.messageDeleted(messages[1].redactedForDeletion()))
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            XCTAssertEqual(model.rows.compactMap(\.messageID), ["first"])
            XCTAssertEqual(
                collection.numberOfItems(inSection: 0), 2, "Remove the bubble and its now-empty day"
            )

            store.apply(.messagesBulkDeleted(.init(chatId: "chat", messageIds: ["first"])))
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            XCTAssertTrue(model.rows.isEmpty)
            XCTAssertEqual(
                collection.numberOfItems(inSection: 0), 0,
                "No deleted placeholder or orphan separator remains")
        }

        func testPreviewPreservesImageOnlyAndOversizedBubbleGeometry() async throws {
            let image = try TimelineTestFixtures.message(
                id: "image-preview", at: 0,
                fields: [
                    "message": NSNull(), "hasAttachments": true,
                    "attachments": [
                        [
                            "id": "portrait", "url": "file:///missing-fixture.png",
                            "kind": "image/png",
                            "size": 1, "fileName": "portrait.png", "width": 400, "height": 1600,
                        ]
                    ],
                ])
            let long = try TimelineTestFixtures.message(
                id: "long-preview", at: 0,
                fields: [
                    "message": String(
                        repeating: "A long message must retain its exact wrapping and width.\n",
                        count: 60)
                ])
            for message in [image, long] {
                let source = BubbleSource(page: try TimelineTestFixtures.page([message]))
                let model = ConversationTimelineModel(
                    chatID: "chat", currentUserID: 1, isGroupChat: true,
                    source: source, messageStore: ConversationMessageStore())
                let root = NavigationStack {
                    MessageInteractionHost(
                        model: model, context: .init(canWrite: true), actions: .init()
                    ) { actions in
                        ConversationTimelineView(
                            model: model, loadsInitialAutomatically: false, actions: actions)
                    }
                    .navigationTitle("Title bar above the timeline")
                }
                let host = UIHostingController(rootView: root)
                let scene = try XCTUnwrap(
                    UIApplication.shared.connectedScenes.first as? UIWindowScene)
                let window = UIWindow(windowScene: scene)
                window.rootViewController = host
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    model.close()
                }
                await model.loadInitial()
                try await Task.sleep(for: .milliseconds(300))
                window.layoutIfNeeded()
                func bubbles(in view: UIView) -> [TimelineBubbleContentView] {
                    if let bubble = view as? TimelineBubbleContentView { return [bubble] }
                    return view.subviews.flatMap { bubbles(in: $0) }
                }
                let original = try XCTUnwrap(bubbles(in: window).first)
                let size = original.bounds.size
                let action = try XCTUnwrap(original.accessibilityCustomActions?.first)
                XCTAssertTrue(try XCTUnwrap(action.actionHandler)(action))
                try await Task.sleep(for: .milliseconds(700))
                window.layoutIfNeeded()
                let visible = bubbles(in: window)
                XCTAssertEqual(visible.count, 2)
                for bubble in visible {
                    XCTAssertEqual(bubble.bounds.width, size.width, accuracy: 0.5)
                    XCTAssertEqual(bubble.bounds.height, size.height, accuracy: 0.5)
                }
            }
        }

        func testSameDayPrependAndViewportChangesPreserveReaderPosition() async throws {
            let messages = try (0..<50).map {
                try TimelineTestFixtures.message(
                    id: "\($0)", senderID: 2, at: $0,
                    text: String(
                        repeating: "A wrapping message keeps its position while history loads. ",
                        count: 3)
                )
            }
            let source = CollectionHistorySource(
                initial: try TimelineTestFixtures.page(Array(messages[20...]), olderCursor: "20"),
                older: try TimelineTestFixtures.page(Array(messages[..<20]))
            )
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: true,
                source: source, messageStore: ConversationMessageStore()
            )
            let parent = UIViewController()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = parent
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let controller = TimelineCollectionViewController(model: model, actions: .init())
            parent.addChild(controller)
            parent.view.addSubview(controller.view)
            controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
            controller.didMove(toParent: parent)
            let collection = try XCTUnwrap(
                controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            collection.contentInsetAdjustmentBehavior = .never
            parent.view.layoutIfNeeded()
            await model.loadInitial()
            controller.viewDidLayoutSubviews()
            try await Task.sleep(for: .milliseconds(100))
            await model.jumpToLiveEdge()
            XCTAssertNil(
                model.updates.value.pendingScroll,
                "A jump already at its destination must finish without an animation callback")

            controller.scrollViewWillBeginDragging(collection)
            collection.setContentOffset(
                CGPoint(x: 0, y: collection.contentOffset.y - 100), animated: false)
            controller.scrollViewDidEndDragging(collection, willDecelerate: false)
            model.revealLatestAfterSend()
            controller.viewDidLayoutSubviews()
            XCTAssertEqual(
                collection.contentSize.height - collection.contentOffset.y
                    - collection.bounds.height, 0, accuracy: 1,
                "Sending must reveal the live edge immediately, without waiting for a scroll animation"
            )

            controller.view.frame.size.height = 350
            parent.view.layoutIfNeeded()
            controller.viewDidLayoutSubviews()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(
                collection.contentSize.height - collection.contentOffset.y
                    - collection.bounds.height, 0, accuracy: 1)
            collection.contentInset.bottom = 80
            controller.viewDidLayoutSubviews()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(
                collection.contentSize.height + collection.adjustedContentInset.bottom
                    - collection.contentOffset.y - collection.bounds.height, 0, accuracy: 1,
                "Bottom attachment must account for a changing composer inset")

            controller.scrollViewWillBeginDragging(collection)
            collection.setContentOffset(.zero, animated: false)
            XCTAssertEqual(
                model.state.older, .loading,
                "Prefetch must start during the gesture, not only at its end")
            let messageID = try XCTUnwrap(model.rows.first { $0.messageID == "20" }).id
            func messageOffset() throws -> CGFloat {
                let index = try XCTUnwrap(model.rows.firstIndex { $0.id == messageID })
                let frame = try XCTUnwrap(
                    collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
                ).frame
                return frame.minY - collection.contentOffset.y - collection.adjustedContentInset.top
            }
            let offset = try messageOffset()
            for _ in 0..<50 {
                if model.rows.contains(where: { $0.messageID == "0" }),
                    collection.numberOfItems(inSection: 0) == model.rows.count
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.rows.compactMap(\.messageID), messages.map(\.id))
            collection.layoutIfNeeded()
            XCTAssertEqual(
                try messageOffset(), offset, accuracy: 1,
                "Anchor the message, not the same-day separator above inserted history")
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(
                try messageOffset(), offset, accuracy: 1,
                "Batch animations must not move the reader after anchor restoration")
            controller.scrollViewDidEndDragging(collection, willDecelerate: false)
            let index = try XCTUnwrap(model.rows.firstIndex { $0.id == messageID })
            let frame = try XCTUnwrap(
                collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
            ).frame
            collection.setContentOffset(CGPoint(x: 0, y: frame.minY + 12), animated: false)
            let resizeOffset = try messageOffset()

            controller.view.frame.size = CGSize(width: 300, height: 450)
            parent.view.layoutIfNeeded()
            controller.viewDidLayoutSubviews()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try messageOffset(), resizeOffset, accuracy: 1)
            XCTAssertFalse(model.state.live.followsLatest)
        }

        func testUnreadEntrySurvivesHeaderGeometryChangeAtScrollCompletion() async throws {
            let messages = try (0..<50).map {
                try TimelineTestFixtures.message(
                    id: "\($0)", senderID: 2, at: $0, text: "Unread entry message \($0)")
            }
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: false,
                source: BubbleSource(page: try TimelineTestFixtures.page(messages)),
                messageStore: ConversationMessageStore()
            )
            let parent = UIViewController()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = parent
            window.makeKeyAndVisible()
            defer {
                model.close()
                window.isHidden = true
            }
            let controller = TimelineCollectionViewController(model: model, actions: .init())
            controller.headerInset = 64
            controller.composerInset = 80
            parent.addChild(controller)
            parent.view.addSubview(controller.view)
            controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 500)
            controller.didMove(toParent: parent)
            parent.view.layoutIfNeeded()
            var adjustedHeader = false
            let observation = model.updates.sink { snapshot in
                guard model.state.content == .ready, snapshot.pendingScroll == nil, !adjustedHeader
                else { return }
                adjustedHeader = true
                controller.headerInset = 100
            }
            defer { observation.cancel() }
            await model.open(position: .unread(after: messages[30].id))
            try await Task.sleep(for: .milliseconds(200))
            controller.view.layoutIfNeeded()
            let collection = try XCTUnwrap(
                controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            let index = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
            let frame = try XCTUnwrap(
                collection.layoutAttributesForItem(at: .init(item: index, section: 0))
            ).frame
            XCTAssertTrue(adjustedHeader)
            XCTAssertEqual(
                frame.minY, collection.contentOffset.y + controller.headerInset, accuracy: 1,
                "Settling the floating header must preserve the unread target, not the pre-jump position."
            )
            XCTAssertFalse(model.state.live.followsLatest)
        }

        func testUnreadMarkerAndReadTrackingRespectFloatingOverlays() async throws {
            let messages = try (0..<16).map {
                try TimelineTestFixtures.message(
                    id: "opaque-\(100 - $0)", senderID: 2, at: $0, text: "Visible message \($0)")
            }
            let pending = PendingOutgoingMessage(
                chatID: "chat", clientGeneratedID: "pending",
                body: .init(
                    messageType: .text, clientGeneratedId: "pending", message: "Not confirmed"),
                enqueuedAt: TimelineTestFixtures.date(second: 16), senderID: 1, state: .queued
            )
            let store = ConversationMessageStore()
            store.replacePending(chatID: "chat", with: [pending])
            var reads: [String] = []
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: false,
                source: BubbleSource(page: try TimelineTestFixtures.page(messages)),
                messageStore: store,
                markRead: { reads.append($0) }
            )
            let parent = UIViewController()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = parent
            window.makeKeyAndVisible()
            defer {
                model.close()
                window.isHidden = true
            }
            let controller = TimelineCollectionViewController(model: model, actions: .init())
            controller.headerInset = 64
            controller.composerInset = 80
            parent.addChild(controller)
            parent.view.addSubview(controller.view)
            controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
            controller.didMove(toParent: parent)
            let collection = try XCTUnwrap(
                controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            collection.contentInsetAdjustmentBehavior = .never
            parent.view.layoutIfNeeded()
            await model.loadInitial(position: .unread(after: messages[3].id))
            controller.viewDidLayoutSubviews()
            try await Task.sleep(for: .milliseconds(100))
            collection.layoutIfNeeded()
            let markerIndex = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
            let markerPath = IndexPath(item: markerIndex, section: 0)
            let markerFrame = try XCTUnwrap(collection.layoutAttributesForItem(at: markerPath))
                .frame
            let marker = try XCTUnwrap(collection.cellForItem(at: markerPath))
            XCTAssertEqual(
                markerFrame.minY, collection.contentOffset.y + controller.headerInset, accuracy: 1)
            let markerLayout = TimelineTestFixtures.layout(
                row: .unreadSeparator, width: 400, parent: controller, cache: TimelineLayoutCache())
            XCTAssertEqual(marker.bounds.height, markerLayout.size.height, accuracy: 0.5)

            model.updateReadState(unreadCount: 5, lastReadMessageID: messages[10].id)
            await model.jumpTowardLatest()
            try await Task.sleep(for: .milliseconds(650))
            let readBoundary = try XCTUnwrap(
                model.rows.firstIndex { $0.messageID == messages[10].id })
            let boundaryFrame = try XCTUnwrap(
                collection.layoutAttributesForItem(at: .init(item: readBoundary, section: 0))
            ).frame
            XCTAssertEqual(
                boundaryFrame.maxY,
                collection.contentOffset.y + collection.bounds.height - controller.composerInset,
                accuracy: 1,
                "The first jump must bottom-align the read boundary above the composer.")
            await model.jumpTowardLatest()
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(
                collection.contentSize.height,
                collection.contentOffset.y + collection.bounds.height - controller.composerInset,
                accuracy: 1,
                "A second jump must reach the actual bottom.")

            func frame(_ messageIndex: Int) throws -> CGRect {
                let index = try XCTUnwrap(
                    model.rows.firstIndex { $0.messageID == messages[messageIndex].id })
                return try XCTUnwrap(
                    collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
                ).frame
            }
            func show(top: CGFloat, bottom: CGFloat) async throws {
                model.setReadTrackingActive(false)
                controller.view.frame.size.height =
                    bottom - top + controller.headerInset + controller.composerInset
                parent.view.layoutIfNeeded()
                controller.viewDidLayoutSubviews()
                try await Task.sleep(for: .milliseconds(100))
                controller.scrollViewWillBeginDragging(collection)
                collection.setContentOffset(
                    CGPoint(x: 0, y: top - controller.headerInset), animated: false)
                collection.layoutIfNeeded()
                controller.scrollViewDidScroll(collection)
                controller.scrollViewDidEndDragging(collection, willDecelerate: false)
                model.setReadTrackingActive(true)
            }

            let partial = try frame(6)
            try await show(
                top: partial.minY + partial.height / 4, bottom: partial.maxY - partial.height / 4)
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(reads, [], "A row clipped by both overlays must never be marked read.")

            try await show(top: try frame(5).midY, bottom: try frame(8).midY)
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(
                reads, [messages[7].id],
                "Choose the last fully visible row, not the partially visible row under the composer."
            )

            try await show(top: try frame(14).midY, bottom: collection.contentSize.height)
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(
                reads, [messages[7].id, messages[15].id],
                "Pending rows cannot advance read progress; opaque IDs remain in timeline order.")
        }

        func testRowHeightsFollowWidthAndDynamicTypeWhileReadingHistory() async throws {
            let messages = try (0..<15).map {
                try TimelineTestFixtures.message(
                    id: "\($0)", senderID: 2, at: $0,
                    text: String(
                        repeating: "A long message must wrap without overlapping the next row. ",
                        count: 5)
                )
            }
            let source = BubbleSource(page: try TimelineTestFixtures.page(messages))
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
                messageStore: ConversationMessageStore())
            let parent = UIViewController()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = parent
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            let controller = TimelineCollectionViewController(model: model, actions: .init())
            parent.addChild(controller)
            parent.view.addSubview(controller.view)
            controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
            controller.didMove(toParent: parent)
            setCategory(.accessibilityExtraLarge, on: controller, parent: parent)
            await model.loadInitial()
            try await Task.sleep(for: .milliseconds(200))

            let collection = try XCTUnwrap(
                controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            // The 800-point fixture can extend beyond a phone window; that is not a safe-area inset.
            collection.contentInsetAdjustmentBehavior = .never
            let referenceMeasurer = TimelineLayoutCache()
            model.userScrollBegan()
            collection.setContentOffset(CGPoint(x: 0, y: 120), animated: false)

            for width: CGFloat in [320, 400, 800] {
                controller.view.frame.size.width = width
                parent.view.layoutIfNeeded()
                controller.viewDidLayoutSubviews()
                try await Task.sleep(for: .milliseconds(100))
                collection.layoutIfNeeded()
                XCTAssertEqual(collection.bounds.width, width, accuracy: 0.5)
                XCTAssertLessThanOrEqual(collection.contentSize.width, width + 0.5)
                var previousBottom: CGFloat = 0
                for index in model.rows.indices {
                    let frame = try XCTUnwrap(
                        collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
                    ).frame
                    let expectedHeight = TimelineTestFixtures.layout(
                        row: model.rows[index], width: width, parent: controller,
                        cache: referenceMeasurer
                    ).size.height
                    XCTAssertEqual(
                        frame.height, expectedHeight, accuracy: 1, "Row \(index) at width \(width)")
                    XCTAssertGreaterThanOrEqual(frame.minY, previousBottom - 0.5)
                    previousBottom = frame.maxY
                }
                XCTAssertFalse(model.state.live.followsLatest)
            }

            let index = try XCTUnwrap(model.rows.firstIndex { $0.messageID == "2" })
            let path = IndexPath(item: index, section: 0)
            collection.scrollToItem(at: path, at: .top, animated: false)
            let before = try XCTUnwrap(collection.layoutAttributesForItem(at: path)).frame.height
            setCategory(.accessibilityExtraExtraExtraLarge, on: controller, parent: parent)
            parent.view.layoutIfNeeded()
            controller.viewDidLayoutSubviews()
            try await Task.sleep(for: .milliseconds(200))
            collection.layoutIfNeeded()
            let after = try XCTUnwrap(collection.layoutAttributesForItem(at: path)).frame.height
            XCTAssertGreaterThan(after, before)
            XCTAssertEqual(
                after,
                TimelineTestFixtures.layout(
                    row: model.rows[index], width: collection.bounds.width, parent: controller,
                    cache: referenceMeasurer
                ).size.height, accuracy: 1)
        }

        func testReplyMediaRowsKeepGeometryWhenOnlyViewportHeightChanges() async throws {
            let message = try TimelineTestFixtures.message(
                id: "reply-media", senderID: 2, at: 0,
                fields: [
                    "message": "Caption below the quoted message.",
                    "hasAttachments": true,
                    "attachments": [
                        [
                            "id": "portrait", "url": "file:///missing-fixture.png",
                            "kind": "image/png",
                            "size": 1, "fileName": "portrait.png", "width": 400, "height": 1600,
                        ]
                    ],
                    "replyToMessage": [
                        "id": "quoted", "clientGeneratedId": "quoted-client",
                        "createdAt": "2026-09-01T00:00:00Z",
                        "sender": ["uid": 3, "gender": 0, "name": "Quoted sender"],
                        "messageType": "text", "attachments": [], "mentions": [],
                        "isDeleted": false, "message": "Quoted text",
                    ],
                    "threadInfo": ["replyCount": 2],
                ])
            let source = BubbleSource(page: try TimelineTestFixtures.page([message]))
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
                messageStore: ConversationMessageStore())
            let parent = UIViewController()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = parent
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let controller = TimelineCollectionViewController(model: model, actions: .init())
            parent.addChild(controller)
            parent.view.addSubview(controller.view)
            controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            controller.didMove(toParent: parent)
            await model.loadInitial()
            try await Task.sleep(for: .milliseconds(200))
            let collection = try XCTUnwrap(
                controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            collection.contentInsetAdjustmentBehavior = .never
            let index = try XCTUnwrap(model.rows.firstIndex { $0.messageID == "reply-media" })
            let path = IndexPath(item: index, section: 0)
            var heights: [CGFloat] = []
            for height: CGFloat in [800, 400, 800] {
                controller.view.frame.size.height = height
                parent.view.layoutIfNeeded()
                controller.viewDidLayoutSubviews()
                try await Task.sleep(for: .milliseconds(100))
                collection.scrollToItem(at: path, at: .top, animated: false)
                collection.layoutIfNeeded()
                let cell = try XCTUnwrap(collection.cellForItem(at: path))
                try assertTextContained(in: cell)
                heights.append(cell.bounds.height)
            }
            XCTAssertEqual(
                heights[0], heights[1], accuracy: 0.5,
                "Viewport height is not a row geometry dependency.")
            XCTAssertEqual(heights[0], heights[2], accuracy: 0.5)
        }

        func testReactionExpansionAndRemovalReflowFollowingMessages() async throws {
            let messages = try (0..<4).map {
                try TimelineTestFixtures.message(
                    id: "reaction-\($0)", senderID: 2, at: $0, text: "Message \($0)")
            }
            let store = ConversationMessageStore()
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: false,
                source: BubbleSource(page: try TimelineTestFixtures.page(messages)),
                messageStore: store
            )
            let parent = UIViewController()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = parent
            window.makeKeyAndVisible()
            defer {
                model.close()
                window.isHidden = true
            }
            let controller = TimelineCollectionViewController(model: model, actions: .init())
            parent.addChild(controller)
            parent.view.addSubview(controller.view)
            controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
            controller.didMove(toParent: parent)
            let collection = try XCTUnwrap(
                controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            collection.contentInsetAdjustmentBehavior = .never
            parent.view.layoutIfNeeded()
            await model.loadInitial()
            try await Task.sleep(for: .milliseconds(200))
            collection.layoutIfNeeded()

            func frames() throws -> [CGRect] {
                try messages.map { message in
                    let index = try XCTUnwrap(model.rows.firstIndex { $0.messageID == message.id })
                    return try XCTUnwrap(
                        collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
                    ).frame
                }
            }
            let initial = try frames()
            let reacted = try TimelineTestFixtures.message(
                id: messages[1].id, senderID: 2, at: 1,
                fields: [
                    "reactions": ["👍", "❤️", "🎉", "👀", "😂", "🔥", "👏", "💯"].map {
                        ["emoji": $0, "count": 12, "reactedByMe": false] as [String: Any]
                    }
                ])
            store.apply(
                .reactionUpdated(
                    .init(messageId: reacted.id, chatId: "chat", reactions: reacted.reactions)))
            try await Task.sleep(for: .milliseconds(200))
            collection.layoutIfNeeded()
            let expanded = try frames()
            let growth = expanded[1].height - initial[1].height
            XCTAssertGreaterThan(
                growth, 0, "Reactions must increase the message's allocated height.")
            XCTAssertEqual(
                expanded[0], initial[0], "Messages before the changed row must not move.")
            for index in 2..<messages.count {
                XCTAssertEqual(expanded[index].minY - initial[index].minY, growth, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(
                    expanded[index].minY, expanded[index - 1].maxY - 0.5,
                    "Following messages must not cover the expanded row.")
            }
            let rowIndex = try XCTUnwrap(model.rows.firstIndex { $0.messageID == reacted.id })
            let cell = try XCTUnwrap(
                collection.cellForItem(at: IndexPath(item: rowIndex, section: 0))
                    as? TimelineCollectionViewCell)
            func reactionView(in view: UIView) -> UIView? {
                if view is TimelineReactionsView { return view }
                return view.subviews.lazy.compactMap { reactionView(in: $0) }.first
            }
            let reactions = try XCTUnwrap(reactionView(in: cell))
            let reactionFrame = cell.convert(reactions.bounds, from: reactions)
            XCTAssertTrue(
                cell.bounds.insetBy(dx: -0.5, dy: -0.5).contains(reactionFrame),
                "The reaction strip must fit inside the allocated cell.")

            store.apply(
                .reactionUpdated(.init(messageId: reacted.id, chatId: "chat", reactions: [])))
            try await Task.sleep(for: .milliseconds(200))
            collection.layoutIfNeeded()
            let collapsed = try frames()
            for index in messages.indices {
                XCTAssertEqual(collapsed[index].minY, initial[index].minY, accuracy: 0.5)
                XCTAssertEqual(
                    collapsed[index].height, initial[index].height, accuracy: 0.5,
                    "Removing the final reaction must reclaim the extra row height.")
            }
        }

        private func assertTextContained(
            in cell: UICollectionViewCell, file: StaticString = #filePath, line: UInt = #line
        ) throws {
            func textViews(in view: UIView) -> [UIKitMessageTextView] {
                if let text = view as? UIKitMessageTextView { return [text] }
                return view.subviews.flatMap { textViews(in: $0) }
            }
            let text = try XCTUnwrap(textViews(in: cell).first, file: file, line: line)
            let rendered = cell.convert(text.bounds, from: text)
            XCTAssertTrue(
                cell.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rendered),
                "Text frame \(rendered) must fit row \(cell.bounds).", file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                cell.bounds.maxY - rendered.maxY, 8,
                "The last text line must not consume the row's bottom padding.", file: file,
                line: line)
            let glyphs = text.contentLayout.layoutManager.usedRect(
                for: text.contentLayout.textContainer
            )
            .offsetBy(dx: text.textContainerInset.left, dy: text.textContainerInset.top)
            XCTAssertTrue(
                text.bounds.insetBy(dx: -0.5, dy: -0.5).contains(glyphs),
                "All glyphs must fit the prepared native text frame.", file: file, line: line)
            for button in text.subviews.compactMap({ $0 as? UIButton }) where !button.isHidden {
                let symbol = button.imageRect(forContentRect: button.bounds)
                let inText = text.convert(symbol, from: button)
                let inRow = cell.convert(symbol, from: button)
                XCTAssertTrue(
                    text.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inText),
                    "Visible retry symbol \(inText) must fit text frame \(text.bounds).",
                    file: file, line: line)
                XCTAssertTrue(
                    cell.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inRow),
                    "Visible retry symbol \(inRow) must fit row \(cell.bounds).", file: file,
                    line: line)
            }
        }

        private func setCategory(
            _ category: UIContentSizeCategory, on controller: UIViewController,
            parent: UIViewController
        ) {
            if #available(iOS 17, *) {
                controller.traitOverrides.preferredContentSizeCategory = category
            } else {
                parent.setOverrideTraitCollection(
                    UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
            }
        }
    }

    @MainActor
    private final class BubbleSource: TimelineMessageSource {
        let page: ListMessagesResponse
        init(page: ListMessagesResponse) { self.page = page }
        func fetchMessages(chatID: String, query: ListMessagesQuery) async throws
            -> ListMessagesResponse
        { page }
    }

    @MainActor
    private final class CollectionHistorySource: TimelineMessageSource {
        let initial: ListMessagesResponse
        let older: ListMessagesResponse

        init(initial: ListMessagesResponse, older: ListMessagesResponse) {
            self.initial = initial
            self.older = older
        }

        func fetchMessages(chatID: String, query: ListMessagesQuery) async throws
            -> ListMessagesResponse
        {
            query.before == nil ? initial : older
        }
    }
#endif
