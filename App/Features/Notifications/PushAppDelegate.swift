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
    weak var coordinator: PushNotificationCoordinator? {
        didSet {
            if let token { coordinator?.didRegister(deviceToken: token) }
            if let response { coordinator?.receiveResponse(response); self.response = nil }
        }
    }
    private var token: Data?
    private var response: PushNotificationRoute?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    // Use the completion-handler witnesses explicitly: the generated async
    // Objective-C bridge can finish on a cooperative executor. UIKit's launch
    // completion updates its snapshot and must run on the main thread.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
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
        let route = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? PushNotificationRoute(userInfo: response.notification.request.content.userInfo) : nil
        Task { @MainActor in
            if let route { receive(route) }
            completionHandler()
        }
    }

    private func receive(_ route: PushNotificationRoute) {
        if let coordinator { coordinator.receiveResponse(route) }
        else { response = route }
    }

    private func registered(_ token: Data) {
        self.token = token
        coordinator?.didRegister(deviceToken: token)
    }
}

#if os(iOS)
extension PushAppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        registered(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        coordinator?.didFailRegistration(error)
    }
}
#else
extension PushAppDelegate: NSApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        registered(deviceToken)
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        coordinator?.didFailRegistration(error)
    }
}
#endif
