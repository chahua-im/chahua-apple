import ChahuaAPI
import Combine
import Foundation
import UserNotifications
import os

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// One subscription owner per authenticated installation. Notification Center
/// owns remote alert delivery and chat/thread grouping; never repost APNs alerts.
@MainActor
final class PushNotificationCoordinator: ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var registrationError: String?
    @Published private(set) var isRegistering = false
    @Published private(set) var isRegistered = false
    @Published private(set) var notificationsDisabled: Bool
    @Published private(set) var isUnregistering = false
    @Published private(set) var pendingNavigation: PushNotificationRoute?

    private struct Registration: Codable, Equatable {
        let uid: Int32
        let token: String
        let environment: APNsEnvironment
    }
    private let api: (any PushSubscriptionProviding)?
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let storageKey: String
    private let environment: APNsEnvironment?
    private let logger = Logger(subsystem: "app.chahua.chat", category: "push")
    private var uid: Int32?
    private var generation = 0
    private var deviceToken: String?
    private var registration: Registration?
    private var registrationTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var isSigningOut = false
    private var activeScenes: Set<UUID> = []
    private var visibleConversations: [UUID: ConversationKey] = [:]

    init(
        api: (any PushSubscriptionProviding)?, namespace: String,
        center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard,
        environment: String? = Bundle.main.object(forInfoDictionaryKey: "ChahuaAPNSEnvironment")
            as? String
    ) {
        self.api = api
        self.center = center
        self.defaults = defaults
        storageKey = "APNsRegistration." + namespace
        notificationsDisabled = defaults.bool(forKey: storageKey + ".disabled")
        switch environment {
        case "development": self.environment = .sandbox
        case "production": self.environment = .production
        default: self.environment = nil
        }
        if let data = defaults.data(forKey: storageKey) {
            registration = try? JSONDecoder().decode(Registration.self, from: data)
        }
    }

    func setSession(uid: Int32?) {
        guard self.uid != uid || uid == nil else { return }
        let priorUID = self.uid ?? registration?.uid
        self.uid = uid
        generation &+= 1
        isSigningOut = false
        isRegistered = false
        isRegistering = false
        isUnregistering = false
        registrationError = nil
        registrationTask?.cancel()
        authorizationTask?.cancel()
        cleanupTask?.cancel()
        if uid == nil || (priorUID != nil && priorUID != uid) {
            pendingNavigation = nil
            visibleConversations.removeAll()
            center.removeAllDeliveredNotifications()
            center.removeAllPendingNotificationRequests()
            Task { try? await center.setBadgeCount(0) }
        }
        if uid == nil {
            unregisterNative()
            return
        }
        authorizationTask = Task { [weak self] in await self?.refreshAuthorization() }
    }

    func setSceneActive(id: UUID, active: Bool) {
        if active { activeScenes.insert(id) } else { activeScenes.remove(id) }
        if active, uid != nil {
            authorizationTask?.cancel()
            authorizationTask = Task { [weak self] in await self?.refreshAuthorization() }
        }
    }

    func removeScene(id: UUID) {
        activeScenes.remove(id)
        visibleConversations.removeValue(forKey: id)
    }

    func setVisibleConversation(sceneID: UUID, conversation: ConversationKey?) {
        visibleConversations[sceneID] = conversation
    }

    func refreshAuthorization() async {
        let requestGeneration = generation
        let settings = await center.notificationSettings()
        guard !Task.isCancelled, requestGeneration == generation else { return }
        authorizationStatus = settings.authorizationStatus
        guard uid != nil, !isSigningOut, !isUnregistering, !notificationsDisabled, api != nil else {
            return
        }
        if permitsNotifications {
            guard environment != nil else {
                registrationError = String(
                    localized: "Push notification environment is not configured.")
                return
            }
            registerNative()
            // Always ask APNs for the current token; a stored token is only for
            // unsubscribing a previous registration, never a substitute for APNs.
            if deviceToken != nil { synchronizeRegistration() }
        } else if authorizationStatus == .denied {
            await registrationTask?.value
            isRegistered = false
            guard requestGeneration == generation, !Task.isCancelled else { return }
            if let registration, registration.uid == uid, let api {
                do {
                    try await api.unsubscribeFromPush(
                        deviceToken: registration.token, environment: registration.environment)
                    guard requestGeneration == generation else { return }
                    clearRegistration()
                    registrationError = nil
                } catch {
                    registrationError = String(
                        localized: "Couldn’t update notification registration. Try again.")
                    logger.error(
                        "Push unsubscribe after permission revocation failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            unregisterNative()
        }
    }

    func requestAuthorization() async {
        guard uid != nil, !isSigningOut, !isUnregistering else { return }
        let requestGeneration = generation
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard requestGeneration == generation, !isSigningOut, !isUnregistering else { return }
            if granted {
                notificationsDisabled = false
                defaults.removeObject(forKey: storageKey + ".disabled")
            }
            registrationError = nil
            await refreshAuthorization()
        } catch {
            guard requestGeneration == generation else { return }
            registrationError = String(
                localized: "Couldn’t request notification permission. Try again.")
        }
    }

    var canDisableNotifications: Bool {
        !notificationsDisabled
            && (permitsNotifications || isRegistered || registration?.uid == uid && uid != nil)
    }

    func disableNotifications() async {
        guard let uid, let api, !isSigningOut, !isUnregistering else { return }
        let requestGeneration = generation
        isUnregistering = true
        registrationError = nil
        authorizationTask?.cancel()
        defer {
            if generation == requestGeneration {
                isUnregistering = false
                isRegistering = false
            }
        }
        // Do not cancel an in-flight subscribe: it must land before unsubscribe.
        await registrationTask?.value
        guard generation == requestGeneration else { return }
        do {
            let previous = registration
            let token = deviceToken
            if let token, let environment {
                try await api.unsubscribeFromPush(deviceToken: token, environment: environment)
            }
            guard generation == requestGeneration else { return }
            if let previous, previous.uid == uid,
                previous.token != token || previous.environment != environment
            {
                try await api.unsubscribeFromPush(
                    deviceToken: previous.token, environment: previous.environment)
            }
            guard generation == requestGeneration else { return }
            notificationsDisabled = true
            defaults.set(true, forKey: storageKey + ".disabled")
            clearRegistration()
            isRegistered = false
            unregisterNative()
        } catch {
            guard generation == requestGeneration else { return }
            registrationError = String(
                localized: "Couldn’t update notification registration. Try again.")
            logger.error("Push disable failed: \(String(describing: error), privacy: .public)")
        }
    }

    func didRegister(deviceToken: Data) {
        self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        synchronizeRegistration()
    }

    func didFailRegistration(_ error: Error) {
        guard uid != nil, !notificationsDisabled, !isUnregistering else { return }
        isRegistering = false
        isRegistered = false
        registrationError = String(
            localized: "Couldn’t register for push notifications. Try again.")
        logger.error("APNs registration failed: \(String(describing: error), privacy: .public)")
    }

    private var permitsNotifications: Bool {
        #if os(iOS)
            if authorizationStatus == .ephemeral { return true }
        #endif
        return authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    private func synchronizeRegistration() {
        guard let api, let uid, let deviceToken, let environment,
            permitsNotifications, !isSigningOut, !isUnregistering, !notificationsDisabled
        else { return }
        let desired = Registration(uid: uid, token: deviceToken, environment: environment)
        let requestGeneration = generation
        let priorTask = registrationTask
        // Serialize token changes. An old subscribe must finish before a new one
        // (or logout's unsubscribe), or it can reassign the token back afterward.
        isRegistering = true
        registrationTask = Task { [weak self] in
            await priorTask?.value
            guard let self, !Task.isCancelled, self.generation == requestGeneration,
                self.permitsNotifications, !self.isSigningOut, !self.isUnregistering,
                !self.notificationsDisabled
            else { return }
            self.isRegistering = true
            defer { if self.generation == requestGeneration { self.isRegistering = false } }
            do {
                try await api.subscribeToPush(
                    deviceToken: desired.token, environment: desired.environment)
                guard !Task.isCancelled, self.generation == requestGeneration, !self.isSigningOut
                else { return }
                self.registration = desired
                self.defaults.set(try JSONEncoder().encode(desired), forKey: self.storageKey)
                self.isRegistered = true
                self.registrationError = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, self.generation == requestGeneration else { return }
                self.isRegistered = false
                self.registrationError = String(
                    localized: "Couldn’t update notification registration. Try again.")
                self.logger.error(
                    "Push subscribe failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Run while the old session JWT is still installed. Failed unsubscribe keeps
    /// logout retryable instead of silently leaving alerts enabled for that user.
    func prepareForSignOut() async throws {
        guard let uid else { return }
        guard !isUnregistering else { throw CancellationError() }
        isSigningOut = true
        authorizationTask?.cancel()
        await registrationTask?.value
        do {
            if let api {
                if let deviceToken, let environment {
                    try await api.unsubscribeFromPush(
                        deviceToken: deviceToken, environment: environment)
                }
                if let registration, registration.uid == uid,
                    registration.token != deviceToken || registration.environment != environment
                {
                    try await api.unsubscribeFromPush(
                        deviceToken: registration.token, environment: registration.environment)
                }
            }
        } catch APIError.invalidToken {
            // A revoked session cannot authorize unsubscribe. Stop native APNs
            // delivery and allow local sign-out instead of trapping the user.
        } catch {
            isSigningOut = false
            registrationError = String(
                localized: "Couldn’t update notification registration. Try again.")
            throw error
        }
        clearRegistration()
        isRegistered = false
        isRegistering = false
        unregisterNative()
    }

    private func clearRegistration() {
        registration = nil
        defaults.removeObject(forKey: storageKey)
    }

    func receiveResponse(_ route: PushNotificationRoute) { pendingNavigation = route }

    func takeNavigation() -> PushNotificationRoute? {
        guard uid != nil else { return nil }
        defer { pendingNavigation = nil }
        return pendingNavigation
    }

    func presentationOptions(for route: PushNotificationRoute) -> UNNotificationPresentationOptions
    {
        guard uid != nil else { return [] }
        if activeScenes.contains(where: { visibleConversations[$0] == route.conversation }) {
            return []
        }
        return [.banner, .list, .sound, .badge]
    }

    func didRead(conversation: ConversationKey, through messageID: String) {
        let requestGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            let delivered = await self.center.deliveredNotifications()
            guard self.generation == requestGeneration else { return }
            let identifiers = delivered.compactMap { notification -> String? in
                guard
                    let route = PushNotificationRoute(
                        userInfo: notification.request.content.userInfo),
                    route.isRead(through: messageID, in: conversation)
                else { return nil }
                return notification.request.identifier
            }
            self.center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    func synchronizeReadState(_ state: ChatState) {
        guard uid != nil else { return }
        let requestGeneration = generation
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            let delivered = await self.center.deliveredNotifications()
            guard !Task.isCancelled, self.generation == requestGeneration else { return }
            var watermarks: [ConversationKey: String] = [:]
            if state.chatListLoadPhase == .loaded {
                for chat in state.chats {
                    watermarks[.init(chatID: chat.id, threadID: nil)] = chat.lastReadMessageId
                }
            }
            if state.threadListLoadPhase == .loaded {
                for thread in state.threads {
                    watermarks[
                        .init(chatID: thread.chatId, threadID: thread.threadRootMessage.id)] =
                        thread.lastReadMessageId
                }
            }
            let identifiers = delivered.compactMap { notification -> String? in
                guard
                    let route = PushNotificationRoute(
                        userInfo: notification.request.content.userInfo),
                    let watermark = watermarks[route.conversation],
                    route.isRead(through: watermark, in: route.conversation)
                else { return nil }
                return notification.request.identifier
            }
            self.center.removeDeliveredNotifications(withIdentifiers: identifiers)
            // Match the backend badge: top-level unread only, excluding muted
            // and archived chats. Thread groups never increment this count.
            if state.chatListLoadPhase == .loaded, !state.isRefreshingChats {
                let now = Date()
                let total = state.chats.filter {
                    !$0.archived && ($0.mutedUntil == nil || $0.mutedUntil! <= now)
                }
                .reduce(Int64(0)) {
                    min(Int64(UInt32.max), $0 + max(0, min(Int64(UInt32.max), $1.unreadCount)))
                }
                try? await self.center.setBadgeCount(Int(total))
            }
        }
    }

    func openSystemSettings() {
        #if os(iOS)
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                UIApplication.shared.open(url)
            }
        #else
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            {
                NSWorkspace.shared.open(url)
            }
        #endif
    }

    private func registerNative() {
        isRegistering = true
        #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
        #else
            NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    private func unregisterNative() {
        #if os(iOS)
            UIApplication.shared.unregisterForRemoteNotifications()
        #else
            NSApplication.shared.unregisterForRemoteNotifications()
        #endif
    }
}
