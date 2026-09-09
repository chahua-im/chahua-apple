#if os(iOS)
import ChahuaAPI
import Combine
import UIKit
import XCTest
@testable import chahua_apple

@MainActor
final class TimelineCollectionViewControllerTests: XCTestCase {
    func testSameDayPrependAndViewportChangesPreserveReaderPosition() async throws {
        let messages = try (0 ..< 50).map {
            try TimelineTestFixtures.message(
                id: "\($0)", senderID: 2, at: $0,
                text: String(repeating: "A wrapping message keeps its position while history loads. ", count: 3)
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
        let collection = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.contentInsetAdjustmentBehavior = .never
        parent.view.layoutIfNeeded()
        await model.loadInitial()
        controller.viewDidLayoutSubviews()
        try await Task.sleep(for: .milliseconds(100))
        await model.jumpToLiveEdge()
        XCTAssertNil(model.updates.value.pendingScroll,
                     "A jump already at its destination must finish without an animation callback")

        controller.view.frame.size.height = 350
        parent.view.layoutIfNeeded()
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(collection.contentSize.height - collection.contentOffset.y - collection.bounds.height, 0, accuracy: 1)
        collection.contentInset.bottom = 80
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(collection.contentSize.height + collection.adjustedContentInset.bottom
                       - collection.contentOffset.y - collection.bounds.height, 0, accuracy: 1,
                       "Bottom attachment must account for a changing composer inset")

        controller.scrollViewWillBeginDragging(collection)
        collection.setContentOffset(.zero, animated: false)
        XCTAssertEqual(model.state.older, .loading, "Prefetch must start during the gesture, not only at its end")
        let messageID = try XCTUnwrap(model.rows.first { $0.messageID == "20" }).id
        func messageOffset() throws -> CGFloat {
            let index = try XCTUnwrap(model.rows.firstIndex { $0.id == messageID })
            let frame = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
            return frame.minY - collection.contentOffset.y - collection.adjustedContentInset.top
        }
        let offset = try messageOffset()
        for _ in 0 ..< 50 {
            if model.rows.contains(where: { $0.messageID == "0" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.rows.compactMap(\.messageID), messages.map(\.id))
        collection.layoutIfNeeded()
        XCTAssertEqual(try messageOffset(), offset, accuracy: 1,
                       "Anchor the message, not the same-day separator above inserted history")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(try messageOffset(), offset, accuracy: 1,
                       "Batch animations must not move the reader after anchor restoration")
        controller.scrollViewDidEndDragging(collection, willDecelerate: false)
        let index = try XCTUnwrap(model.rows.firstIndex { $0.id == messageID })
        let frame = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
        collection.setContentOffset(CGPoint(x: 0, y: frame.minY + 12), animated: false)
        let resizeOffset = try messageOffset()

        controller.view.frame.size = CGSize(width: 300, height: 450)
        parent.view.layoutIfNeeded()
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(try messageOffset(), resizeOffset, accuracy: 1)
        XCTAssertFalse(model.state.live.followsLatest)
    }

    func testRowHeightsFollowWidthAndDynamicTypeWhileReadingHistory() async throws {
        let messages = try (0 ..< 15).map {
            try TimelineTestFixtures.message(
                id: "\($0)", senderID: 2, at: $0,
                text: String(repeating: "A long message must wrap without overlapping the next row. ", count: 5)
            )
        }
        let source = BubbleSource(page: try TimelineTestFixtures.page(messages))
        let model = ConversationTimelineModel(chatID: "chat", currentUserID: 1, isGroupChat: true, source: source, messageStore: ConversationMessageStore())
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

        let collection = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        // The 800-point fixture can extend beyond a phone window; that is not a safe-area inset.
        collection.contentInsetAdjustmentBehavior = .never
        let referenceMeasurer = TimelineRowMeasurer(parent: controller)
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
                let frame = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
                let expectedHeight = referenceMeasurer.height(for: model.rows[index], width: width)
                XCTAssertEqual(frame.height, expectedHeight, accuracy: 1, "Row \(index) at width \(width)")
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
        try await Task.sleep(for: .milliseconds(200))
        parent.view.layoutIfNeeded()
        collection.layoutIfNeeded()
        let after = try XCTUnwrap(collection.layoutAttributesForItem(at: path)).frame.height
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(after, referenceMeasurer.height(for: model.rows[index], width: collection.bounds.width), accuracy: 1)
    }

    func testFailedMetadataMatchesMeasuredRowsAcrossResizeAndAcknowledgement() async throws {
        let text = "Unsent text\n你好，世界 " + String(repeating: "Wrapping message. ", count: 3)
        let pending = PendingOutgoingMessage(
            chatID: "chat", clientGeneratedID: "failed-text",
            body: .init(messageType: .text, clientGeneratedId: "failed-text", message: text),
            enqueuedAt: TimelineTestFixtures.date(second: 0), senderID: 1, state: .failed
        )
        let store = ConversationMessageStore()
        store.replacePending(chatID: "chat", with: [pending])
        let source = BubbleSource(page: try TimelineTestFixtures.page([]))
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source, messageStore: store
        )
        let parent = UIViewController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let controller = TimelineCollectionViewController(
            model: model, actions: .init(openFailedMessage: { _ in XCTFail("Rendering must not activate retry.") })
        )
        parent.addChild(controller)
        parent.view.addSubview(controller.view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 900)
        controller.didMove(toParent: parent)
        setCategory(.accessibilityExtraLarge, on: controller, parent: parent)
        await model.loadInitial()
        try await Task.sleep(for: .milliseconds(200))
        let collection = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.contentInsetAdjustmentBehavior = .never
        let measurer = TimelineRowMeasurer(parent: controller)
        for width: CGFloat in [320, 600, 900] {
            controller.view.frame.size.width = width
            controller.overrideUserInterfaceStyle = width == 600 ? .dark : .light
            parent.view.layoutIfNeeded()
            controller.viewDidLayoutSubviews()
            try await Task.sleep(for: .milliseconds(100))
            collection.layoutIfNeeded()
            let index = try XCTUnwrap(model.rows.firstIndex { $0.stableMessageKey == .clientGenerated("failed-text") })
            let path = IndexPath(item: index, section: 0)
            collection.scrollToItem(at: path, at: .bottom, animated: false)
            collection.layoutIfNeeded()
            let cell = try XCTUnwrap(collection.cellForItem(at: path))
            cell.layoutIfNeeded()
            let renderedSize = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            XCTAssertEqual(cell.bounds.height, renderedSize.height, accuracy: 1)
            XCTAssertEqual(cell.bounds.height, measurer.height(for: model.rows[index], width: width), accuracy: 1,
                           "The hidden measurer without actions must reserve the visible failure control.")
            let image = UIGraphicsImageRenderer(size: cell.bounds.size).image { context in
                cell.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "ios-failed-message-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let acknowledgement = try TimelineTestFixtures.message(
            id: "delivered-text", at: 0, clientGeneratedID: "failed-text", fields: ["message": text]
        )
        store.replacePending(chatID: "chat", with: [], acknowledging: acknowledgement)
        controller.viewDidLayoutSubviews()
        try await Task.sleep(for: .milliseconds(100))
        collection.layoutIfNeeded()
        let index = try XCTUnwrap(model.rows.firstIndex { $0.messageID == "delivered-text" })
        let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: index, section: 0)))
        XCTAssertEqual(cell.bounds.height, measurer.height(for: model.rows[index], width: collection.bounds.width), accuracy: 1)
        let image = UIGraphicsImageRenderer(size: cell.bounds.size).image { context in
            cell.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "ios-acknowledged-message"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func setCategory(_ category: UIContentSizeCategory, on controller: UIViewController, parent: UIViewController) {
        if #available(iOS 17, *) {
            controller.traitOverrides.preferredContentSizeCategory = category
        } else {
            parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
        }
    }
}

@MainActor
private final class BubbleSource: TimelineMessageSource {
    let page: ListMessagesResponse
    init(page: ListMessagesResponse) { self.page = page }
    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse { page }
}

@MainActor
private final class CollectionHistorySource: TimelineMessageSource {
    let initial: ListMessagesResponse
    let older: ListMessagesResponse

    init(initial: ListMessagesResponse, older: ListMessagesResponse) {
        self.initial = initial
        self.older = older
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        query.before == nil ? initial : older
    }
}
#endif
