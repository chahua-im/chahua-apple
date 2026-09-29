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

    weak var coordinator: PushNotificationCoordinator? {
        didSet {
            if let token { coordinator?.didRegister(deviceToken: token) }
            if let response {
                coordinator?.receiveResponse(response)
                self.response = nil
            }
            if let quickReply {
                self.quickReply = nil
                let handoff = quickReplyHandoff
                quickReplyHandoff = nil
                Task { [weak coordinator] in
                    _ = await coordinator?.receiveQuickReply(
                        quickReply.route, userText: quickReply.text)
                    handoff?.resume()
                }
            }
        }
    }
    private var token: Data?
    private var response: PushNotificationRoute?
    private var quickReply: (route: PushNotificationRoute, text: String)?
    private var quickReplyHandoff: CheckedContinuation<Void, Never>?

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
        let quickReply =
            response.actionIdentifier == QuickReply.actionIdentifier
            ? (response as? UNTextInputNotificationResponse).map { (route, $0.userText) }
            : nil
        Task { @MainActor in
            if let quickReply, let route = quickReply.0 {
                await receiveQuickReply(route, text: quickReply.1)
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let route
            {
                receive(route)
            }
            completionHandler()
        }
    }

    private func receive(_ route: PushNotificationRoute) {
        if let coordinator { coordinator.receiveResponse(route) } else { response = route }
    }
    private func receiveQuickReply(_ route: PushNotificationRoute, text: String) async {
        if let coordinator {
            _ = await coordinator.receiveQuickReply(route, userText: text)
            return
        }
        await withCheckedContinuation { continuation in
            quickReply = (route, text)
            quickReplyHandoff = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finishQuickReplyHandoff()
            }
        }
    }

    private func finishQuickReplyHandoff() {
        quickReplyHandoff?.resume()
        quickReplyHandoff = nil
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
