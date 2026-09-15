import ChahuaAPI
import XCTest
import UserNotifications
@testable import chahua_apple

@MainActor
final class PushNotificationTests: XCTestCase {
    func testBackgroundNotificationTapCompletesOnMainAndSurvivesColdStart() async throws {
        let center = UNUserNotificationCenter.current()
        let previousDelegate = center.delegate
        defer { center.delegate = previousDelegate }
        let appDelegate = PushAppDelegate()
        let delegate: any UNUserNotificationCenterDelegate = appDelegate
        let notification = try makeNotification(userInfo: ["wettyChat": [
            "type": "reply", "chatId": "42", "messageId": "101", "threadRootId": "100"
        ]])
        let response = try XCTUnwrap(UNNotificationResponse(coder: NotificationDecoder([
            "notification": notification, "actionIdentifier": UNNotificationDefaultActionIdentifier
        ])))
        let completed = expectation(description: "Notification launch completion")
        completed.assertForOverFulfill = true
        await Task.detached {
            delegate.userNotificationCenter?(center, didReceive: response, withCompletionHandler: {
                XCTAssertTrue(Thread.isMainThread, "UIKit's notification launch completion must run on the main thread.")
                completed.fulfill()
            })
        }.value
        await fulfillment(of: [completed], timeout: 2)

        let notifications = PushNotificationCoordinator(api: nil, namespace: UUID().uuidString)
        appDelegate.coordinator = notifications
        notifications.setSession(uid: 1)
        let route = try XCTUnwrap(notifications.takeNavigation())
        XCTAssertEqual(route.conversation, ConversationKey(chatID: "42", threadID: "100"))
        XCTAssertEqual(route.messageID, "101")
        XCTAssertNil(notifications.takeNavigation())
    }

    func testIgnoredNotificationStillCompletesOnMainWithoutNavigation() async throws {
        let center = UNUserNotificationCenter.current()
        let previousDelegate = center.delegate
        defer { center.delegate = previousDelegate }
        let appDelegate = PushAppDelegate()
        let notifications = PushNotificationCoordinator(api: nil, namespace: UUID().uuidString)
        appDelegate.coordinator = notifications
        let delegate: any UNUserNotificationCenterDelegate = appDelegate
        let response = try XCTUnwrap(UNNotificationResponse(coder: NotificationDecoder([
            "notification": try makeNotification(userInfo: [:]),
            "actionIdentifier": UNNotificationDefaultActionIdentifier
        ])))
        let completed = expectation(description: "Ignored notification completion")
        await Task.detached {
            delegate.userNotificationCenter?(center, didReceive: response, withCompletionHandler: {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            })
        }.value
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(notifications.pendingNavigation)
    }

    private func makeNotification(userInfo: [AnyHashable: Any]) throws -> UNNotification {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        return try XCTUnwrap(UNNotification(coder: NotificationDecoder(["request": request, "date": Date()])))
    }

    func testDisablePersistsAcrossRelaunchAndLateTokenCallbacks() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = PushSubscriptionStore()
        let notifications = PushNotificationCoordinator(api: api, namespace: suite, defaults: defaults, environment: "development")
        notifications.setSession(uid: 1)
        notifications.didRegister(deviceToken: Data([1, 2]))
        await notifications.disableNotifications()
        XCTAssertTrue(notifications.notificationsDisabled)
        XCTAssertFalse(notifications.isRegistered)
        let subscribed = await api.isSubscribed
        XCTAssertFalse(subscribed)

        let restored = PushNotificationCoordinator(api: api, namespace: suite, defaults: defaults, environment: "development")
        restored.setSession(uid: 1)
        restored.didRegister(deviceToken: Data([1, 2]))
        await restored.refreshAuthorization()
        XCTAssertTrue(restored.notificationsDisabled)
        XCTAssertFalse(restored.isRegistered)
        XCTAssertFalse(restored.isRegistering)
    }

    func testFailedUnsubscribeDoesNotClaimDisabledAndCanBeRetried() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = PushSubscriptionStore()
        await api.setFailUnsubscribe(true)
        let notifications = PushNotificationCoordinator(api: api, namespace: suite, defaults: defaults, environment: "development")
        notifications.setSession(uid: 1)
        notifications.didRegister(deviceToken: Data([1, 2]))
        await notifications.disableNotifications()
        XCTAssertFalse(notifications.notificationsDisabled)
        XCTAssertNotNil(notifications.registrationError)
        XCTAssertFalse(notifications.isUnregistering)

        await api.setFailUnsubscribe(false)
        await notifications.disableNotifications()
        XCTAssertTrue(notifications.notificationsDisabled)
        XCTAssertNil(notifications.registrationError)
    }

    func testThreadGroupsRemainSeparateFromParentChatAndOtherThreads() throws {
        let chat = try XCTUnwrap(PushNotificationRoute(userInfo: ["wettyChat": [
            "type": "newMessage", "chatId": "42", "messageId": "9007199254740993"
        ]]))
        let reply = try XCTUnwrap(PushNotificationRoute(userInfo: ["wettyChat": [
            "type": "reply", "chatId": "42", "messageId": "9007199254740994", "threadRootId": "100"
        ]]))
        let mention = try XCTUnwrap(PushNotificationRoute(userInfo: ["wettyChat": [
            "type": "mention", "chatId": "42", "messageId": "9007199254740995", "threadRootId": "101"
        ]]))
        XCTAssertEqual(chat.groupingIdentifier, "chat_42")
        XCTAssertEqual(reply.groupingIdentifier, "chat_42_thread_100")
        XCTAssertEqual(mention.groupingIdentifier, "chat_42_thread_101")
        XCTAssertEqual(reply.messageID, "9007199254740994")
        XCTAssertFalse(reply.isRead(through: "9007199254740995", in: chat.conversation))
        XCTAssertFalse(reply.isRead(through: "9007199254740995", in: mention.conversation))
        XCTAssertFalse(reply.isRead(through: "9007199254740993", in: reply.conversation))
        XCTAssertTrue(reply.isRead(through: "9007199254740994", in: reply.conversation))
    }

    func testMalformedPayloadCannotBecomeNavigation() {
        XCTAssertNil(PushNotificationRoute(userInfo: ["data": ["chatId": "42", "messageId": "100"]]))
        XCTAssertNil(PushNotificationRoute(userInfo: ["wettyChat": [
            "type": "newMessage", "chatId": "42", "messageId": 9007199254740993 as Int64
        ]]))
        XCTAssertNil(PushNotificationRoute(userInfo: ["wettyChat": [
            "type": "newMessage", "chatId": "42", "messageId": "100", "threadRootId": ""
        ]]))
        XCTAssertNil(PushNotificationRoute(userInfo: ["wettyChat": [
            "type": "unknown", "chatId": "42", "messageId": "100"
        ]]))
    }

    func testColdLaunchRouteIsClaimedOnceAndAccountSwitchDiscardsOldRoute() throws {
        let notifications = PushNotificationCoordinator(api: nil, namespace: UUID().uuidString)
        let route = try XCTUnwrap(PushNotificationRoute(userInfo: ["wettyChat": [
            "type": "newMessage", "chatId": "42", "messageId": "100"
        ]]))
        notifications.receiveResponse(route)
        XCTAssertNil(notifications.takeNavigation())
        notifications.setSession(uid: 1)
        XCTAssertEqual(notifications.takeNavigation(), route)
        XCTAssertNil(notifications.takeNavigation())
        notifications.receiveResponse(route)
        notifications.setSession(uid: 2)
        XCTAssertNil(notifications.takeNavigation())
    }

    func testForegroundSuppressionRequiresSameConversationInActiveScene() throws {
        let notifications = PushNotificationCoordinator(api: nil, namespace: UUID().uuidString)
        let route = try XCTUnwrap(PushNotificationRoute(userInfo: ["wettyChat": [
            "type": "reply", "chatId": "42", "messageId": "101", "threadRootId": "100"
        ]]))
        notifications.setSession(uid: 1)
        let scene = UUID()
        notifications.setSceneActive(id: scene, active: true)
        notifications.setVisibleConversation(sceneID: scene, conversation: .init(chatID: "42", threadID: nil))
        XCTAssertTrue(notifications.presentationOptions(for: route).contains(.banner))
        notifications.setVisibleConversation(sceneID: scene, conversation: route.conversation)
        XCTAssertEqual(notifications.presentationOptions(for: route), [])
        notifications.setSceneActive(id: scene, active: false)
        XCTAssertTrue(notifications.presentationOptions(for: route).contains(.banner))
        notifications.removeScene(id: scene)
        notifications.setSceneActive(id: scene, active: true)
        XCTAssertTrue(notifications.presentationOptions(for: route).contains(.banner))
    }
}

private actor PushSubscriptionStore: PushSubscriptionProviding {
    private var tokens: Set<String> = ["0102"]
    private var failUnsubscribe = false
    var isSubscribed: Bool { tokens.contains("0102") }

    func setFailUnsubscribe(_ value: Bool) { failUnsubscribe = value }

    func subscribeToPush(deviceToken: String, environment: APNsEnvironment) async throws {
        tokens.insert(deviceToken)
    }

    func unsubscribeFromPush(deviceToken: String, environment: APNsEnvironment) async throws {
        if failUnsubscribe { throw URLError(.notConnectedToInternet) }
        tokens.remove(deviceToken)
    }
}

/// Decode the system notification types through their public NSCoding API;
/// Apple does not expose memberwise initializers for delivered notifications.
private final class NotificationDecoder: NSCoder {
    private let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
    override var allowsKeyedCoding: Bool { true }
    override func decodeObject(forKey key: String) -> Any? { values[key] }
}
