#if os(iOS)
import ChahuaAPI
import UIKit
import XCTest
@testable import chahua_apple

@MainActor
final class TimelineCollectionViewControllerTests: XCTestCase {
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

        let controller = TimelineCollectionViewController(model: model)
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
#endif
