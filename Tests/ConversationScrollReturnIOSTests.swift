#if os(iOS)
    import ChahuaAPI
    import SwiftUI
    import UIKit
    import XCTest

    @testable import chahua_apple

    @MainActor
    final class ConversationScrollReturnIOSTests: XCTestCase {
        func testChatToThreadBackRestoresVisibleMessageAndPixelOffset() async throws {
            try await exercise(.thread, layout: .phone)
        }

        func testChatToForwardedMessagesBackRestoresVisibleMessageAndPixelOffset() async throws {
            try await exercise(.forwarded, layout: .phone)
        }

        func testChatToThreadToForwardedMessagesBackRestoresEveryLevel() async throws {
            try await exercise(.threadThenForwarded, layout: .phone)
        }

        func testForwardedToNestedForwardedMessagesBackRestoresEveryLevel() async throws {
            try await exercise(.nestedForwarded, layout: .phone)
        }

        func testSplitChatToThreadBackRestoresVisibleMessageAndPixelOffset() async throws {
            try await exercise(.thread, layout: .split)
        }

        func testSplitChatToForwardedMessagesBackRestoresVisibleMessageAndPixelOffset() async throws
        {
            try await exercise(.forwarded, layout: .split)
        }

        func testSplitChatToThreadToForwardedMessagesBackRestoresEveryLevel() async throws {
            try await exercise(.threadThenForwarded, layout: .split)
        }

        func testSplitForwardedToNestedForwardedMessagesBackRestoresEveryLevel() async throws {
            try await exercise(.nestedForwarded, layout: .split)
        }

        private enum Route {
            case thread, forwarded, threadThenForwarded, nestedForwarded
        }

        private enum Layout {
            case phone, split

            var size: CGSize {
                switch self {
                case .phone: CGSize(width: 390, height: 844)
                case .split: CGSize(width: 1100, height: 844)
                }
            }
        }

        private struct Anchor: Equatable {
            let messageID: MessageID
            let offset: CGFloat
        }

        private struct Geometry: Equatable {
            let offset: CGPoint
            let size: CGSize
            let contentSize: CGSize
            let insets: UIEdgeInsets
            let rows: [Anchor]
        }

        private struct Page {
            let navigation: UINavigationController
            let controller: TimelineCollectionViewController
            let collection: UICollectionView
        }

        private func exercise(_ route: Route, layout: Layout) async throws {
            // Keep phone and split independently runnable: a failed navigation in
            // one shell branch must not prevent exercising the other branch.
            let fixture = try await makeFixture(layout: layout)
            do {
                try await navigate(route, fixture: fixture, layout: layout)
            } catch {
                fixture.unmount()
                try? await fixture.close()
                throw error
            }
            fixture.unmount()
            try await fixture.close()
        }

        private func navigate(_ route: Route, fixture: Fixture, layout: Layout) async throws {
            let chat = try await settledPage(in: fixture.window, firstID: 1)
            XCTAssertEqual(
                chat.controller.isWideChatLayout, layout == .split,
                "The requested AuthenticatedShell layout must actually be mounted")
            let chatAnchor = try await scrollAndCapture(
                chat, item: 40, firstID: 1, fixture: fixture)

            switch route {
            case .thread, .threadThenForwarded:
                let root = try row(MessageID(40), in: chat.collection)
                let label = try XCTUnwrap(root.binding?.presentation.threadLabel)
                let button = try XCTUnwrap(
                    views(UIButton.self, in: root).first {
                        $0.accessibilityLabel == label && $0.isEnabled && !$0.isHidden
                    })
                button.sendActions(for: .primaryActionTriggered)
                let thread = try await settledPage(in: fixture.window, firstID: 1001)
                let threadAnchor = try await scrollAndCapture(
                    thread, item: route == .thread ? 70 : 40, firstID: 1001, fixture: fixture)
                XCTAssertNotEqual(threadAnchor.messageID, chatAnchor.messageID)
                if route == .threadThenForwarded {
                    try openForwarded(MessageID(1040), on: thread)
                    let forwarded = try await settledPage(in: fixture.window, firstID: 2001)
                    _ = try await scrollAndCapture(
                        forwarded, item: 70, firstID: 2001, fixture: fixture)
                    try pressBack(on: forwarded)
                    try await assertReturned(
                        threadAnchor, firstID: 1001, fixture: fixture,
                        context: "\(layout): forwarded → thread")
                }
                let returningThread = try await settledPage(in: fixture.window, firstID: 1001)
                try pressBack(on: returningThread)
                try await assertReturned(
                    chatAnchor, firstID: 1, fixture: fixture,
                    context: "\(layout): thread → chat")

            case .forwarded, .nestedForwarded:
                try openForwarded(MessageID(40), on: chat)
                let forwarded = try await settledPage(in: fixture.window, firstID: 2001)
                let forwardedAnchor = try await scrollAndCapture(
                    forwarded, item: route == .nestedForwarded ? 40 : 70,
                    firstID: 2001, fixture: fixture)
                if route == .nestedForwarded {
                    try openForwarded(MessageID(2040), on: forwarded)
                    let nested = try await settledPage(in: fixture.window, firstID: 3001)
                    let nestedAnchor = try await scrollAndCapture(
                        nested, item: 70, firstID: 3001, fixture: fixture)
                    XCTAssertNotEqual(nestedAnchor.messageID, forwardedAnchor.messageID)
                    try pressBack(on: nested)
                    try await assertReturned(
                        forwardedAnchor, firstID: 2001, fixture: fixture,
                        context: "\(layout): nested forwarded → forwarded")
                }
                let returningForwarded = try await settledPage(in: fixture.window, firstID: 2001)
                try pressBack(on: returningForwarded)
                try await assertReturned(
                    chatAnchor, firstID: 1, fixture: fixture,
                    context: "\(layout): forwarded → chat")
            }
        }

        private func openForwarded(_ id: MessageID, on page: Page) throws {
            let source = try row(id, in: page.collection)
            let card = try XCTUnwrap(
                views(TimelineForwardedCardView.self, in: source).first { !$0.isHidden })
            XCTAssertTrue(card.isEnabled)
            XCTAssertTrue(
                page.collection.bounds.inset(by: page.collection.adjustedContentInset)
                    .intersects(card.convert(card.bounds, to: page.collection)),
                "The forwarded card action must be visible to the reader")
            card.sendActions(for: .touchUpInside)
        }

        private func pressBack(on page: Page) throws {
            if !page.navigation.isNavigationBarHidden {
                // UIKit's system Back accessibility element does not activate in
                // an in-process host. Use its real navigation controller pop, as
                // the existing forwarded-navigation integration test does.
                _ = try XCTUnwrap(
                    page.navigation.popViewController(animated: false),
                    "Forwarded records must have a native Back destination")
                return
            }
            let top = try XCTUnwrap(page.navigation.topViewController)
            let root = try XCTUnwrap(top.view)
            let elements = accessibilityElements(in: root)
            let button =
                elements.first {
                    $0.accessibilityLabel == AppLanguage.localized("Back")
                        && $0.accessibilityTraits.contains(.button)
                }
                ?? elements.first {
                    $0.accessibilityTraits.contains(.button)
                        && $0.accessibilityFrame.midX
                            < root.convert(root.bounds, to: nil).midX
                }
            XCTAssertTrue(
                try XCTUnwrap(button, "Visible Back control missing").accessibilityActivate())
        }

        private func scrollAndCapture(
            _ page: Page, item: Int, firstID: UInt64, fixture: Fixture
        ) async throws -> Anchor {
            let collection = page.collection
            XCTAssertGreaterThan(collection.contentSize.height, collection.bounds.height * 3)
            // Drive the real UIScrollView and its normal user-scroll lifecycle, not
            // model.jumpToMessage or a test-owned navigation/position model.
            page.controller.scrollViewWillBeginDragging(collection)
            collection.scrollToItem(
                at: IndexPath(item: item, section: 0), at: .centeredVertically, animated: false)
            collection.setContentOffset(
                CGPoint(x: collection.contentOffset.x, y: collection.contentOffset.y + 17),
                animated: false)
            page.controller.scrollViewDidScroll(collection)
            page.controller.scrollViewDidEndDragging(collection, willDecelerate: false)
            let settled = try await settledPage(in: fixture.window, firstID: firstID)
            assertOffLiveEdge(settled, firstID: firstID)
            return try XCTUnwrap(geometry(of: settled).rows.first)
        }

        private func assertReturned(
            _ expected: Anchor, firstID: UInt64, fixture: Fixture, context: String,
            file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            // Wait for *any* stable geometry, never for the expected anchor: a
            // stable but reset viewport must fail, rather than time out or be repaired.
            let page = try await settledPage(in: fixture.window, firstID: firstID)
            let actual = try XCTUnwrap(geometry(of: page).rows.first, file: file, line: line)
            XCTAssertEqual(actual.messageID, expected.messageID, context, file: file, line: line)
            XCTAssertEqual(
                actual.offset, expected.offset, accuracy: 1, context, file: file, line: line)
            assertOffLiveEdge(page, firstID: firstID, file: file, line: line)
        }

        private func assertOffLiveEdge(
            _ page: Page, firstID: UInt64, file: StaticString = #filePath, line: UInt = #line
        ) {
            let collection = page.collection
            let bottom = max(
                -collection.adjustedContentInset.top,
                collection.contentSize.height - collection.bounds.height
                    + collection.adjustedContentInset.bottom)
            XCTAssertGreaterThan(
                bottom - collection.contentOffset.y, collection.bounds.height,
                "Fixture must be reading history, not trivially preserving the live edge",
                file: file, line: line)
            XCTAssertFalse(
                geometry(of: page).rows.contains { $0.messageID == MessageID(firstID + 99) },
                "Newest message must be outside the visible viewport", file: file, line: line)
        }

        private func settledPage(in window: UIWindow, firstID: UInt64) async throws -> Page {
            var previous: Geometry?
            var stableSamples = 0
            for _ in 0..<200 {
                window.layoutIfNeeded()
                if let page = visiblePage(in: window, firstID: firstID),
                    page.navigation.transitionCoordinator == nil,
                    page.collection.numberOfItems(inSection: 0) >= 100,
                    !page.collection.isDragging, !page.collection.isDecelerating
                {
                    let sample = geometry(of: page)
                    if !sample.rows.isEmpty, sample == previous {
                        stableSamples += 1
                        if stableSamples >= 10 { return page }
                    } else {
                        stableSamples = 0
                    }
                    previous = sample
                } else {
                    previous = nil
                    stableSamples = 0
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Unsettled scroll-return page \(firstID)"
            attachment.lifetime = .keepAlways
            add(attachment)
            return try XCTUnwrap(nil as Page?, "Visible timeline did not settle for \(firstID)")
        }

        private func visiblePage(in window: UIWindow, firstID: UInt64) -> Page? {
            guard let root = window.rootViewController else { return nil }
            for navigation in controllers(UINavigationController.self, in: root) {
                guard let top = navigation.topViewController else { continue }
                for controller in controllers(TimelineCollectionViewController.self, in: top) {
                    guard controller.isViewLoaded, controller.view.window === window,
                        let collection = views(UICollectionView.self, in: controller.view).first,
                        collection.bounds.height > 0,
                        views(TimelineRowView.self, in: collection).contains(where: { row in
                            guard let id = row.binding?.presentation.row.messageID else {
                                return false
                            }
                            return id >= MessageID(firstID) && id < MessageID(firstID + 100)
                        })
                    else { continue }
                    return Page(
                        navigation: navigation, controller: controller, collection: collection)
                }
            }
            return nil
        }

        private func geometry(of page: Page) -> Geometry {
            let collection = page.collection
            let insets = collection.adjustedContentInset
            let viewport = CGRect(
                x: collection.bounds.minX + insets.left,
                y: collection.bounds.minY + insets.top,
                width: collection.bounds.width - insets.left - insets.right,
                height: collection.bounds.height - insets.top - insets.bottom)
            let rows = views(TimelineRowView.self, in: collection).compactMap { row -> Anchor? in
                guard !row.isHidden, let id = row.binding?.presentation.row.messageID else {
                    return nil
                }
                let frame = row.convert(row.bounds, to: collection)
                guard frame.intersects(viewport) else { return nil }
                return Anchor(messageID: id, offset: frame.minY - viewport.minY)
            }.sorted { $0.offset < $1.offset }
            return Geometry(
                offset: collection.contentOffset, size: collection.bounds.size,
                contentSize: collection.contentSize, insets: insets, rows: rows)
        }

        private func row(_ id: MessageID, in collection: UICollectionView) throws -> TimelineRowView
        {
            let viewport = collection.bounds.inset(by: collection.adjustedContentInset)
            return try XCTUnwrap(
                views(TimelineRowView.self, in: collection).first {
                    !$0.isHidden && $0.binding?.presentation.row.messageID == id
                        && $0.convert($0.bounds, to: collection).intersects(viewport)
                }, "The real message action must be in a visible mounted native row")
        }

        private func views<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { views(type, in: $0) }
        }

        private func controllers<T: UIViewController>(_ type: T.Type, in root: UIViewController)
            -> [T]
        {
            (root as? T).map { [$0] } ?? root.children.flatMap { controllers(type, in: $0) }
        }

        private func accessibilityElements(in root: NSObject) -> [NSObject] {
            var visited = Set<ObjectIdentifier>()
            func collect(_ object: NSObject) -> [NSObject] {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
                let count = object.accessibilityElementCount()
                let exposed =
                    count > 0 && count < 1000
                    ? (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
                    : []
                let children = exposed + ((object as? UIView)?.subviews ?? [])
                return [object] + children.flatMap(collect)
            }
            return collect(root)
        }

        @MainActor
        private struct Fixture {
            let window: UIWindow
            let previousWindow: UIWindow?
            let store: ChatStore
            let notifications: PushNotificationCoordinator
            let cache: AccountHistoryCache
            let owner: AccountLocalStoreOwner
            let local: ChahuaLocalStore
            let directory: URL
            let defaults: UserDefaults
            let suite: String

            func unmount() {
                window.isHidden = true
                window.rootViewController = nil
                store.reset()
                previousWindow?.makeKey()
            }

            func close() async throws {
                await cache.fenceForSignOut()
                cache.setSession(uid: nil)
                owner.setSession(uid: nil)
                try local.close()
                try FileManager.default.removeItem(at: directory)
                defaults.removePersistentDomain(forName: suite)
            }
        }

        private func makeFixture(layout: Layout) async throws -> Fixture {
            let chatID = "27"
            func messages(firstID: UInt64, thread: Bool = false) throws -> [MessageResponse] {
                try (0..<100).map { index in
                    let id = firstID + UInt64(index)
                    var fields: [String: Any] = [:]
                    if thread { fields["replyRootId"] = "40" }
                    if index == 39 {
                        fields["forwardedBundleId"] = "root"
                        fields["forwardedPreview"] = [
                            "total": 100, "containsForwardedMessages": true, "messages": [],
                        ]
                        if !thread { fields["threadInfo"] = ["replyCount": 100] }
                    }
                    return try TimelineTestFixtures.message(
                        id: id, chatID: chatID, senderID: 2, at: index % 60,
                        minute: index / 60, type: index == 39 ? .forwarded : .text,
                        text:
                            "History message \(id). A second sentence gives every level real scrollable history.",
                        fields: fields)
                }
            }
            func forwarded(firstID: UInt64, nested: Bool) throws -> ForwardedMessagesResponse {
                let entries = try (0..<100).map { index in
                    let source = try TimelineTestFixtures.message(
                        id: firstID + UInt64(index), chatID: "captured", senderID: 2,
                        at: index % 60, minute: index / 60,
                        text:
                            "Captured history \(firstID + UInt64(index)). Its viewport must return unchanged."
                    )
                    return ForwardedMessageResponse(
                        originalMessageId: source.id, originalChatId: source.chatId,
                        message: source.message,
                        messageType: nested && index == 39 ? .forwarded : .text,
                        sender: source.sender, originalCreatedAt: source.createdAt,
                        forwardedBundleId: nested && index == 39 ? "child" : nil)
                }
                return .init(total: entries.count, messages: entries)
            }
            let chatMessages = try messages(firstID: 1)
            let chat = ChatListItem(
                id: chatID, name: "Scroll return", unreadCount: 0, archived: false, kind: .group)
            let api = FakeChatAPI(chatResults: [.success(.init(chats: [chat]))])
            await api.setPolicyTargetedChat(chat)
            await api.setPolicyMessagePage(chatMessages, chatID: chatID)
            await api.setPolicyMessagePage(
                try messages(firstID: 1001, thread: true), chatID: chatID, threadID: "40")
            await api.setConversationPageMetadata(
                group: .init(id: chatID, myRole: .admin, kind: .group))
            await api.setNotificationMessage(try XCTUnwrap(chatMessages.last))
            await api.setForwardedResponses([
                try forwarded(firstID: 2001, nested: true),
                try forwarded(firstID: 3001, nested: false),
            ])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ScrollReturnIOS-\(UUID().uuidString)", isDirectory: true)
            let local = try ChahuaLocalStore(directory: directory, userID: 1)
            let owner = AccountLocalStoreOwner { _ in local }
            owner.setSession(uid: 1)
            let cache = AccountHistoryCache(owner: owner)
            cache.setSession(uid: 1)
            let store = ChatStore(
                apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api),
                historyCache: cache, onInvalidToken: {})
            let me = try JSONDecoder().decode(
                MeResponse.self,
                from: Data(
                    #"{"uid":1,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                        .utf8))
            store.currentUserProfile = me
            let suite = "ScrollReturnIOS.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let notifications = PushNotificationCoordinator(
                api: nil, namespace: suite, defaults: defaults,
                authorizationStatusProvider: { .denied })
            // Enter through the app's real incoming-message-link route, initially
            // at the newest message so reopening that route cannot fake restoration.
            var pendingURL: URL? = try XCTUnwrap(
                MessagePermalink(chatID: chatID, messageID: MessageID(100))
            ).url
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: layout.size)
            let shell = AuthenticatedShell(
                chatStore: store, notifications: notifications, notificationSceneID: UUID(),
                me: me, isSigningOut: false, onSignOut: {},
                pendingURL: Binding(get: { pendingURL }, set: { pendingURL = $0 })
            )
            .environment(\.scenePhase, .active)
            .environment(\.conversationDisplayValues, ConversationDisplayValues())
            .defaultAppStorage(defaults)
            .frame(width: layout.size.width, height: layout.size.height)
            window.rootViewController = UIHostingController(rootView: shell)
            window.makeKeyAndVisible()
            return Fixture(
                window: window, previousWindow: previous, store: store,
                notifications: notifications,
                cache: cache, owner: owner, local: local, directory: directory,
                defaults: defaults, suite: suite)
        }
    }
#endif
