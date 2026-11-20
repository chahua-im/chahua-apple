import Foundation
import UserNotifications

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Installed before launch finishes so notification taps survive cold startup.
/// SwiftUI supplies no APNs token callbacks; the native delegate is required on
/// both platforms. Only the composition root starts authenticated services.
@MainActor
final class PushAppDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private enum QuickReply {
        // Must match the backend's aps.category; the category selects system actions.
        static let categoryIdentifier = "chahua"
        static let actionIdentifier = "quickReply"
    }

    @MainActor
    private final class QuickReplyCompletion {
        private var handler: (@Sendable () -> Void)?

        init(_ handler: @escaping @Sendable () -> Void) {
            self.handler = handler
        }

        func finish() {
            let handler = self.handler
            self.handler = nil
            handler?()
        }
    }

    weak var coordinator: PushNotificationCoordinator? {
        didSet {
            if let token { coordinator?.didRegister(deviceToken: token) }
            if let response {
                coordinator?.receiveResponse(response)
                self.response = nil
            }
            if let coordinator {
                let handoffs = quickReplyHandoffs
                quickReplyHandoffs.removeAll()
                for handoff in handoffs { handoff(coordinator) }
            }
        }
    }
    #if os(iOS)
        weak var outboxRefresh: OutboxRefreshScheduler?
    #endif
    private var token: Data?
    private var response: PushNotificationRoute?
    private var quickReplyHandoffs: [@MainActor (PushNotificationCoordinator) -> Void] = []

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Platform exception: SwiftUI cannot register notification actions, and
        // APNs delivers their text-input responses only through this delegate.
        let action = UNTextInputNotificationAction(
            identifier: QuickReply.actionIdentifier, title: String(localized: "Reply"),
            options: [], textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "Message"))
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: QuickReply.categoryIdentifier, actions: [action],
                intentIdentifiers: [], options: [])
        ])
    }
    // Use the completion-handler witnesses explicitly: the generated async
    // Objective-C bridge can finish on a cooperative executor. UIKit's launch
    // completion updates its snapshot and must run on the main thread.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let route = PushNotificationRoute(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            completionHandler(route.map { coordinator?.presentationOptions(for: $0) ?? [] } ?? [])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let route = PushNotificationRoute(userInfo: response.notification.request.content.userInfo)
        if response.actionIdentifier == QuickReply.actionIdentifier,
            let text = (response as? UNTextInputNotificationResponse)?.userText, let route
        {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            Task { @MainActor in
                await receiveQuickReply(
                    route, text: text, deadline: deadline, completionHandler: completionHandler)
            }
        } else {
            let isTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            Task { @MainActor in
                if isTap, let route { receive(route) }
                completionHandler()
            }
        }
    }

    private func receive(_ route: PushNotificationRoute) {
        if let coordinator { coordinator.receiveResponse(route) } else { response = route }
    }
    private func receiveQuickReply(
        _ route: PushNotificationRoute, text: String, deadline: ContinuousClock.Instant,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        if let coordinator {
            await coordinator.receiveQuickReply(route, userText: text, deadline: deadline)
            completionHandler()
            return
        }
        let completion = QuickReplyCompletion(completionHandler)
        let timeout = Task { @MainActor in
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch {
                return
            }
            completion.finish()
        }
        // The OS callback can finish before launch is ready, but handing off
        // the reply later must not grant a fresh background window.
        quickReplyHandoffs.append { coordinator in
            timeout.cancel()
            Task {
                await coordinator.receiveQuickReply(
                    route, userText: text, deadline: deadline, receivedBeforeCoordinator: true)
                completion.finish()
            }
        }
    }

    private func registered(_ token: Data) {
        self.token = token
        coordinator?.didRegister(deviceToken: token)
    }
}

#if os(iOS)
    extension PushAppDelegate: UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            outboxRefresh?.register()
            return true
        }

        func application(
            _ application: UIApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            registered(deviceToken)
        }
        func application(
            _ application: UIApplication,
            didFailToRegisterForRemoteNotificationsWithError error: Error
        ) {
            coordinator?.didFailRegistration(error)
        }
    }

#else
    extension PushAppDelegate: NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            // The app-scoped websocket continues to receive badge updates until Quit.
            false
        }
        func application(
            _ application: NSApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            registered(deviceToken)
        }
        func application(
            _ application: NSApplication,
            didFailToRegisterForRemoteNotificationsWithError error: Error
        ) {
            coordinator?.didFailRegistration(error)
        }
    }
#endif
