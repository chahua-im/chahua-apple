#if os(iOS)
    import UIKit
    import XCTest
    @testable import chahua_apple

    @MainActor
    final class ConversationSwipeBackTests: XCTestCase {
        func testArchiveEnablesEdgeBackPreservesRowSwipesAndRestoresNativeDelegates() async throws {
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .first(where: { $0.activationState == .foregroundActive }))
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let root = AppearanceReportingController()
            let rootAppeared = expectation(description: "The navigation root appeared")
            root.didAppear = rootAppeared
            let navigation = UINavigationController(rootViewController: root)
            let observer = NavigationAppearanceObserver()
            navigation.delegate = observer
            navigation.setNavigationBarHidden(true, animated: false)
            window.rootViewController = navigation
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
                withExtendedLifetime(observer) {}
            }
            window.makeKeyAndVisible()
            // Window attachment/layout alone does not deliver UIKit's appearance callbacks.
            // Wait for the real presentation before pushing or inspecting pop recognizers.
            await fulfillment(of: [rootAppeared], timeout: 2)
            let edge = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
            let originalEdgeDelegate = edge.delegate
            let originalEdgeEnabled = edge.isEnabled
            let archive = ConversationSwipeBack.Controller()
            archive.allowsContentSwipeBack = false
            if #available(iOS 26, *) {
                let content = try XCTUnwrap(navigation.interactiveContentPopGestureRecognizer)
                let originalContentDelegate = content.delegate
                let originalContentEnabled = content.isEnabled
                let archiveShown = expectation(description: "The archive finished appearing")
                observer.expect(archive, shown: archiveShown)
                navigation.pushViewController(archive, animated: false)
                await fulfillment(of: [archiveShown], timeout: 2)
                XCTAssertNil(navigation.transitionCoordinator)
                XCTAssertTrue(edge.isEnabled)
                XCTAssertTrue(edge.delegate === archive)
                XCTAssertTrue(archive.gestureRecognizerShouldBegin(edge))
                XCTAssertTrue(content.delegate === archive)
                XCTAssertFalse(
                    content.isEnabled, "Row swipes must not start full-content navigation")
                let rootShown = expectation(description: "The archive returned to the root")
                observer.expect(root, shown: rootShown)
                XCTAssertTrue(navigation.popViewController(animated: false) === archive)
                await fulfillment(of: [rootShown], timeout: 2)
                XCTAssertTrue(edge.delegate === originalEdgeDelegate)
                XCTAssertEqual(edge.isEnabled, originalEdgeEnabled)
                XCTAssertTrue(content.delegate === originalContentDelegate)
                XCTAssertEqual(content.isEnabled, originalContentEnabled)
                let conversation = ConversationSwipeBack.Controller()
                let conversationShown = expectation(
                    description: "The conversation finished appearing")
                observer.expect(conversation, shown: conversationShown)
                navigation.pushViewController(conversation, animated: false)
                await fulfillment(of: [conversationShown], timeout: 2)
                XCTAssertNil(navigation.transitionCoordinator)
                XCTAssertTrue(edge.isEnabled)
                XCTAssertTrue(edge.delegate === conversation)
                XCTAssertTrue(conversation.gestureRecognizerShouldBegin(edge))
                XCTAssertTrue(content.isEnabled)
                XCTAssertTrue(content.delegate === conversation)
                XCTAssertTrue(conversation.gestureRecognizerShouldBegin(content))
                let rootShownAgain = expectation(
                    description: "The conversation returned to the root")
                observer.expect(root, shown: rootShownAgain)
                XCTAssertTrue(navigation.popViewController(animated: false) === conversation)
                await fulfillment(of: [rootShownAgain], timeout: 2)
                XCTAssertTrue(edge.delegate === originalEdgeDelegate)
                XCTAssertEqual(edge.isEnabled, originalEdgeEnabled)
                XCTAssertTrue(content.delegate === originalContentDelegate)
                XCTAssertEqual(content.isEnabled, originalContentEnabled)
            } else {
                let archiveShown = expectation(description: "The archive finished appearing")
                observer.expect(archive, shown: archiveShown)
                navigation.pushViewController(archive, animated: false)
                await fulfillment(of: [archiveShown], timeout: 2)
                XCTAssertNil(navigation.transitionCoordinator)
                XCTAssertTrue(edge.isEnabled)
                XCTAssertTrue(edge.delegate === archive)
                XCTAssertTrue(archive.gestureRecognizerShouldBegin(edge))
                let rootShown = expectation(description: "The archive returned to the root")
                observer.expect(root, shown: rootShown)
                XCTAssertTrue(navigation.popViewController(animated: false) === archive)
                await fulfillment(of: [rootShown], timeout: 2)
                XCTAssertTrue(edge.delegate === originalEdgeDelegate)
                XCTAssertEqual(edge.isEnabled, originalEdgeEnabled)
            }
        }
    }

    @MainActor
    private final class AppearanceReportingController: UIViewController {
        var didAppear: XCTestExpectation?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppear?.fulfill()
            didAppear = nil
        }
    }

    @MainActor
    private final class NavigationAppearanceObserver: NSObject, UINavigationControllerDelegate {
        private weak var expectedController: UIViewController?
        private var shown: XCTestExpectation?

        func expect(_ controller: UIViewController, shown: XCTestExpectation) {
            expectedController = controller
            self.shown = shown
        }

        func navigationController(
            _ navigationController: UINavigationController,
            didShow viewController: UIViewController,
            animated: Bool
        ) {
            guard viewController === expectedController else { return }
            shown?.fulfill()
            shown = nil
            expectedController = nil
        }
    }
#endif
