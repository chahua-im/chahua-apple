import ChahuaAPI
import Combine
import Foundation
import Security
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
    @Published private(set) var deviceTokenSuffix: String?
    @Published private(set) var isUnregistering = false
    @Published private(set) var pendingNavigation: PushNotificationRoute?

    private struct PendingQuickReply {
        let id: UUID
        let route: PushNotificationRoute
        let text: String
        let ownerUID: Int32
        let deadline: ContinuousClock.Instant
    }

    private struct QuickReplyWaiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }

    private struct Registration: Codable, Equatable {
        let uid: Int32
        let token: String
        let environment: APNsEnvironment
    }
    private let api: (any PushSubscriptionProviding)?
    private let center: UNUserNotificationCenter
    private let authorizationStatusProvider: @MainActor @Sendable () async -> UNAuthorizationStatus
    private let authorizationRequester: @MainActor @Sendable () async throws -> Bool
    private let defaults: UserDefaults
    private let storageKey: String
    private let environment: APNsEnvironment?
    let configuredEnvironment: APNsEnvironment?
    let signedEnvironment: APNsEnvironment?
    private let logger = Logger(subsystem: "app.chahua.chat", category: "push")
    private var uid: Int32?
    private var generation = 0
    private var deviceToken: String?
    private var registration: Registration?
    private var registrationTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var automaticAuthorizationRequested = false
    private var isRequestingAuthorization = false
    private var cleanupTask: Task<Void, Never>?
    private var isSigningOut = false
    private var signOutUnregistered = false
    private var activeScenes: Set<UUID> = []
    private var visibleConversations: [UUID: ConversationKey] = [:]
    private var quickReplySender:
        (
            @MainActor @Sendable (
                Int32, PushNotificationRoute, String, ContinuousClock.Instant
            ) async throws -> Void
        )?
    private var pendingQuickReplies: [PendingQuickReply] = []
    private var quickReplyTask: (id: UUID, task: Task<Void, Never>)?
    private var quickReplyWaiters: [UUID: QuickReplyWaiter] = [:]

    init(
        api: (any PushSubscriptionProviding)?, namespace: String,
        center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard,
        environment: String? = Bundle.main.object(forInfoDictionaryKey: "ChahuaAPNSEnvironment")
            as? String,
        signedEntitlement: String? = nil,
        authorizationStatusProvider: (@MainActor @Sendable () async -> UNAuthorizationStatus)? =
            nil,
        authorizationRequester: (@MainActor @Sendable () async throws -> Bool)? = nil
    ) {
        self.api = api
        self.center = center
        self.authorizationStatusProvider =
            authorizationStatusProvider ?? {
                await center.notificationSettings().authorizationStatus
            }
        self.authorizationRequester =
            authorizationRequester ?? {
                try await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
        self.defaults = defaults
        storageKey = "APNsRegistration." + namespace
        notificationsDisabled = defaults.bool(forKey: storageKey + ".disabled")
        switch environment {
        case "development": configuredEnvironment = .sandbox
        case "production": configuredEnvironment = .production
        default: configuredEnvironment = nil
        }
        switch signedEntitlement ?? Self.apnsEntitlementValue() {
        case "development": signedEnvironment = .sandbox
        case "production": signedEnvironment = .production
        default: signedEnvironment = nil
        }
        // macOS can route using the signed entitlement instead of potentially
        // mismatched Info.plist metadata. iOS cannot inspect its entitlement;
        // both values come from APNS_ENVIRONMENT in the project build settings.
        self.environment = signedEnvironment ?? configuredEnvironment
        if let data = defaults.data(forKey: storageKey) {
            registration = try? JSONDecoder().decode(Registration.self, from: data)
        }
    }
    private static func apnsEntitlementValue() -> String? {
        #if os(macOS)
            guard let task = SecTaskCreateFromSelf(nil) else { return nil }
            return SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.aps-environment" as CFString, nil) as? String
        #else
            // iOS does not make SecTask entitlement inspection available to apps.
            // The build setting populates both Info.plist and the signing request.
            return nil
        #endif
    }

    var apnsEnvironment: APNsEnvironment? { environment }
    var backendEnvironment: APNsEnvironment? {
        guard isRegistered, registration?.uid == uid else { return nil }
        return registration?.environment
    }

    func setSession(uid: Int32?) {
        guard self.uid != uid || uid == nil else {
            startQuickReplyHandoff()
            return
        }
        let priorUID = self.uid ?? registration?.uid
        self.uid = uid
        generation &+= 1
        automaticAuthorizationRequested = false
        isSigningOut = false
        signOutUnregistered = false
        isRegistered = false
        isRegistering = false
        isUnregistering = false
        registrationError = nil
        registrationTask?.cancel()
        authorizationTask?.cancel()
        cleanupTask?.cancel()
        if uid == nil || (priorUID != nil && priorUID != uid) {
            pendingNavigation = nil
            quickReplyTask?.task.cancel()
            quickReplyTask = nil
            for reply in pendingQuickReplies { finishQuickReplyWaiter(reply.id, accepted: false) }
            pendingQuickReplies.removeAll()
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
        startQuickReplyHandoff()
    }

    func setSceneActive(id: UUID, active: Bool) {
        if active { activeScenes.insert(id) } else { activeScenes.remove(id) }
        // The system prompt can change scene activity. Keep its task alive so
        // its result still refreshes permission and registers the current token.
        if active, uid != nil, !isRequestingAuthorization {
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
        let status = await authorizationStatusProvider()
        guard !Task.isCancelled, requestGeneration == generation else { return }
        authorizationStatus = status
        guard uid != nil, !isSigningOut, !isUnregistering, !notificationsDisabled, api != nil else {
            return
        }
        if status == .notDetermined, !activeScenes.isEmpty,
            !automaticAuthorizationRequested, !isRequestingAuthorization
        {
            // Claim before suspension: multiple windows and repeated session
            // callbacks must not prompt twice for one authenticated session.
            automaticAuthorizationRequested = true
            await requestAuthorization()
            return
        }
        if permitsNotifications {
            guard environment != nil else {
                registrationError = AppLanguage.localized(
                    "Push notification environment is not configured.")
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
                    registrationError = AppLanguage.localized(
                        "Couldn’t update notification registration. Try again.")
                    logger.error(
                        "Push unsubscribe after permission revocation failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            unregisterNative()
        }
    }

    func requestAuthorization() async {
        guard uid != nil, !isSigningOut, !isUnregistering, !isRequestingAuthorization else {
            return
        }
        isRequestingAuthorization = true
        let requestGeneration = generation
        defer {
            isRequestingAuthorization = false
            // A different account can sign in while the system prompt is open.
            // Refresh its permission without applying the old session's result.
            if requestGeneration != generation, uid != nil {
                authorizationTask = Task { [weak self] in await self?.refreshAuthorization() }
            }
        }
        do {
            let granted = try await authorizationRequester()
            guard requestGeneration == generation, !isSigningOut, !isUnregistering else { return }
            if granted {
                notificationsDisabled = false
                defaults.removeObject(forKey: storageKey + ".disabled")
            }
            registrationError = nil
            await refreshAuthorization()
        } catch {
            guard requestGeneration == generation else { return }
            registrationError = AppLanguage.localized(
                "Couldn’t request notification permission. Try again.")
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
            registrationError = AppLanguage.localized(
                "Couldn’t update notification registration. Try again.")
            logger.error("Push disable failed: \(String(describing: error), privacy: .public)")
        }
    }

    func didRegister(deviceToken: Data) {
        self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        deviceTokenSuffix = String(self.deviceToken?.suffix(8) ?? "")
        synchronizeRegistration()
    }

    func didFailRegistration(_ error: Error) {
        guard uid != nil, !notificationsDisabled, !isUnregistering else { return }
        isRegistering = false
        isRegistered = false
        registrationError =
            AppLanguage.localized("Couldn’t register for push notifications. Try again.")
            + " " + error.localizedDescription
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
                self.registrationError = AppLanguage.localized(
                    "Couldn’t update notification registration. Try again.")
                self.logger.error(
                    "Push subscribe failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Run while the old session JWT is still installed. Failed unsubscribe keeps
    /// logout retryable instead of silently leaving alerts enabled for that user.
    func prepareForSignOut() async throws {
        guard let uid, !signOutUnregistered else { return }
        guard !isSigningOut, !isUnregistering else { throw CancellationError() }
        let current = generation
        isSigningOut = true
        authorizationTask?.cancel()
        await registrationTask?.value
        guard generation == current else { throw CancellationError() }
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
            guard generation == current else { throw CancellationError() }
        } catch APIError.invalidToken {
            // A revoked session cannot authorize unsubscribe. Stop native APNs
            // delivery and allow local sign-out instead of trapping the user.
        } catch {
            guard generation == current else { throw CancellationError() }
            isSigningOut = false
            registrationError = AppLanguage.localized(
                "Couldn’t update notification registration. Try again.")
            throw error
        }
        guard generation == current else { throw CancellationError() }
        signOutUnregistered = true
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

    func setQuickReplySender(
        _ sender:
            @escaping @MainActor @Sendable (
                Int32, PushNotificationRoute, String, ContinuousClock.Instant
            ) async throws -> Void
    ) {
        quickReplySender = sender
        startQuickReplyHandoff()
    }

    /// Acknowledges only a durable enqueue within the action's original window.
    /// Expiring the acknowledgment does not cancel the durable handoff.
    @discardableResult
    func receiveQuickReply(
        _ route: PushNotificationRoute, userText: String, deadline: ContinuousClock.Instant,
        receivedBeforeCoordinator: Bool = false
    ) async -> Bool {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // A cold response belongs to the last APNs registration, not to an
        // unrelated session that may have become active while launch was pending.
        let ownerUID = receivedBeforeCoordinator ? registration?.uid : uid ?? registration?.uid
        guard let ownerUID, uid == nil || uid == ownerUID else {
            logger.notice("Discarding unscoped notification quick reply")
            return false
        }
        let id = UUID()
        pendingQuickReplies.append(
            .init(id: id, route: route, text: text, ownerUID: ownerUID, deadline: deadline))
        startQuickReplyHandoff()
        guard ContinuousClock.now < deadline else { return false }
        return await withCheckedContinuation { continuation in
            let timeout = Task { [weak self] in
                do {
                    try await ContinuousClock().sleep(until: deadline)
                } catch {
                    return
                }
                self?.finishQuickReplyWaiter(id, accepted: false)
            }
            quickReplyWaiters[id] = QuickReplyWaiter(continuation: continuation, timeout: timeout)
        }
    }

    private func startQuickReplyHandoff() {
        guard quickReplyTask == nil, uid != nil, !isSigningOut, quickReplySender != nil,
            !pendingQuickReplies.isEmpty
        else { return }
        let id = UUID()
        let task = Task<Void, Never> { [weak self] in
            await self?.sendPendingQuickReplies(taskID: id)
        }
        quickReplyTask = (id, task)
    }

    private func sendPendingQuickReplies(taskID: UUID) async {
        defer {
            if quickReplyTask?.id == taskID { quickReplyTask = nil }
        }
        while let reply = pendingQuickReplies.first {
            guard quickReplyTask?.id == taskID, !isSigningOut, uid == reply.ownerUID,
                let sender = quickReplySender
            else { return }
            do {
                try await sender(reply.ownerUID, reply.route, reply.text, reply.deadline)
            } catch {
                // Keep the system-provided text until a future authenticated
                // session handoff can safely enqueue it.
                if !(error is CancellationError) {
                    logger.error(
                        "Notification quick reply enqueue failed: \(String(describing: error), privacy: .public)"
                    )
                }
                finishQuickReplyWaiter(reply.id, accepted: false)
                return
            }
            guard quickReplyTask?.id == taskID, uid == reply.ownerUID,
                pendingQuickReplies.first?.id == reply.id
            else { return }
            pendingQuickReplies.removeFirst()
            finishQuickReplyWaiter(
                reply.id, accepted: !isSigningOut && ContinuousClock.now < reply.deadline)
        }
    }

    private func finishQuickReplyWaiter(_ id: UUID, accepted: Bool) {
        guard let waiter = quickReplyWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: accepted)
    }

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

    func didRead(conversation: ConversationKey, through messageID: MessageID) {
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
            var watermarks: [ConversationKey: MessageID] = [:]
            if state.chatListLoadPhase == .loaded {
                for chat in state.chats {
                    watermarks[.init(chatID: chat.id, threadID: nil)] = chat.lastReadMessageId
                }
            }
            if state.threadListLoadPhase == .loaded {
                for thread in state.threads {
                    watermarks[thread.conversationKey] = thread.lastReadMessageId
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
            if state.appBadgeCount != nil {
                try? await self.center.setBadgeCount(state.unreadBadgeCount())
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
