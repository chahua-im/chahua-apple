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
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let route = PushNotificationRoute(userInfo: notification.request.content.userInfo) else { return [] }
        return await presentationOptions(for: route)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = PushNotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }
        await receive(route)
    }

    private func presentationOptions(for route: PushNotificationRoute) -> UNNotificationPresentationOptions {
        coordinator?.presentationOptions(for: route) ?? []
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
