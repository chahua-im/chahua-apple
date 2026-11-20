import ChahuaAPI
import Combine
import Foundation

@MainActor
final class AppCompositionRoot {
    let sessionModel: AuthSessionModel
    let chatStore: ChatStore
    private(set) var mediaContext: AppMediaContext?
    let connectivity: ConnectivityMonitor
    let realtimeCoordinator: RealtimeCoordinator
    let notifications: PushNotificationCoordinator
    let localStorage: AccountLocalStoreOwner
    #if os(iOS)
        let outboxRefresh: OutboxRefreshScheduler?
    #endif
    private var chatObservation: AnyCancellable?
    private var pathObservation: AnyCancellable?
    private var lastPathStatus: ConnectivitySnapshot.Status = .unknown

    convenience init(apiConfiguration: ChahuaConfiguration) {
        let client = ChahuaClient(configuration: apiConfiguration)
        self.init(
            apiClient: client,
            authenticationClient: client,
            realtimeProvider: client,
            credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: KeychainTokenStorage(),
            mediaNamespace: apiConfiguration.baseURL.absoluteString,
            productionLifecycle: true,
            localStoreFactory: { uid in
                try await Task.detached {
                    let root = try FileManager.default.url(
                        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                        create: true)
                    let directory = LocalStorageScope(
                        apiBaseURL: apiConfiguration.baseURL, userID: uid
                    ).directory(under: root)
                    let store = try ChahuaLocalStore(directory: directory, userID: uid)
                    // Transient SQLite journals inherit the account directory's
                    // exclusion. This directory also holds device-local outbox files.
                    var accountURL = directory
                    var backup = URLResourceValues()
                    backup.isExcludedFromBackup = true
                    try accountURL.setResourceValues(backup)
                    return store
                }.value
            }
        )
    }

    init(
        apiClient: any ChahuaAPIClient,
        authenticationClient: any SessionAuthenticating,
        realtimeProvider: any RealtimeConnectionProviding,
        credentialLoginClient: any CredentialLoginProviding,
        tokenStorage: any SessionTokenStorage,
        mediaNamespace: String = "injected",
        preferenceDefaults: UserDefaults = .standard,
        productionLifecycle: Bool = false,
        localStoreFactory: @escaping @Sendable (Int32) async throws -> ChahuaLocalStore
    ) {
        let connectivity = ConnectivityMonitor(monitorNetwork: productionLifecycle)
        self.connectivity = connectivity
        let sessionModel = AuthSessionModel(
            apiClient: authenticationClient,
            credentialLoginClient: credentialLoginClient,
            tokenStorage: tokenStorage,
            baseURL: mediaNamespace
        )
        self.sessionModel = sessionModel
        let invalidToken: @MainActor @Sendable () async -> Void = { [weak sessionModel] in
            await sessionModel?.sessionDidExpire()
        }
        let localStorage = AccountLocalStoreOwner(factory: localStoreFactory)
        self.localStorage = localStorage
        let historyCache = AccountHistoryCache(owner: localStorage)
        #if os(macOS)
            let runsWhileInactive = productionLifecycle
        #else
            let runsWhileInactive = false
        #endif
        let outgoingQueue = OutgoingMessageQueue(
            apiClient: apiClient, storage: localStorage, onInvalidToken: invalidToken,
            runsWhileInactive: runsWhileInactive, initiallyForeground: !productionLifecycle,
            retryJitter: { productionLifecycle ? Double.random(in: 0...0.2) : 0 }
        )
        chatStore = ChatStore(
            apiClient: apiClient, outgoingQueue: outgoingQueue,
            displayPreferences: ConversationDisplayPreferences(
                defaults: preferenceDefaults, namespace: mediaNamespace),
            historyCache: historyCache,
            onInvalidToken: invalidToken)
        if productionLifecycle { chatStore.setForegroundActive(false) }
        #if os(iOS)
            outboxRefresh = productionLifecycle
                ? OutboxRefreshScheduler(queue: outgoingQueue, session: sessionModel) : nil
        #endif
        historyCache.onClear = { [weak chatStore, weak outgoingQueue] in
            chatStore?.clearHistoryPresentation()
            outgoingQueue?.compactHistoryWhenIdle()
        }
        historyCache.onDiskFull = { [weak chatStore] in chatStore?.messageStorageFull = true }
        outgoingQueue.onDiskFull = { [weak historyCache] in historyCache?.pauseForDiskFull() }
        chatStore.onRetrySessionValidation = { [weak sessionModel] in sessionModel?.retry() }
        realtimeCoordinator = RealtimeCoordinator(
            provider: realtimeProvider, store: chatStore, onInvalidToken: invalidToken)
        notifications = PushNotificationCoordinator(
            api: apiClient as? any PushSubscriptionProviding, namespace: mediaNamespace)
        notifications.setQuickReplySender {
            [weak sessionModel, weak outgoingQueue] uid, route, text, deadline in
            guard let sessionModel, let outgoingQueue,
                case .authenticated(let me) = sessionModel.state, me.uid == uid
            else { throw CancellationError() }
            // Session bootstrap may still be opening the account-scoped outbox
            // when a cold-launch action arrives. Wait for it before persisting.
            await outgoingQueue.activate(uid: uid)
            try Task.checkCancellation()
            guard case .authenticated(let me) = sessionModel.state, me.uid == uid else {
                throw CancellationError()
            }
            try await outgoingQueue.enqueueIndependentText(
                chatID: route.chatID, threadID: route.threadID, text: text,
                notificationDeadline: deadline)
        }
        sessionModel.prepareForSignOut = { [weak notifications, weak chatStore, weak outgoingQueue] in
            guard let notifications, let chatStore, let outgoingQueue else { throw CancellationError() }
            chatStore.drafts.fenceForSignOut()
            outgoingQueue.fenceForSignOut()
            await chatStore.historyCache?.fenceForSignOut()
            do {
                try await notifications.prepareForSignOut()
                try await outgoingQueue.purgeForSignOut()
            } catch {
                await outgoingQueue.resumeAfterUnregisterFailure()
                chatStore.drafts.resumeAfterUnregisterFailure()
                chatStore.historyCache?.resumeAfterSignOutFailure()
                throw error
            }
        }
        chatStore.onNotificationRead = { [weak notifications] conversation, messageID in
            notifications?.didRead(conversation: conversation, through: messageID)
        }
        chatObservation = chatStore.$state.sink { [weak notifications] state in
            guard sessionModel.sessionValidation == .verified else { return }
            notifications?.synchronizeReadState(state)
        }
        sessionModel.willTransitionSession = { [weak self] state in
            guard let self else { return }
            if case .authenticated(let me) = state {
                if self.chatStore.currentUserProfile?.uid != me.uid {
                    self.mediaContext?.setNetworkAuthorized(false)
                    self.mediaContext?.clearMemoryCache()
                    self.mediaContext = AppMediaContext(
                        namespace: "\(mediaNamespace)|account:\(me.uid)", connectivity: self.connectivity)
                }
                let verified = self.sessionModel.sessionValidation == .verified
                self.mediaContext?.setNetworkAuthorized(verified)
                self.realtimeCoordinator.setSession(uid: me.uid, verified: verified)
                self.chatStore.displayPreferences.activate(uid: me.uid)
                self.chatStore.currentUserProfile = me
                self.notifications.setSession(uid: verified ? me.uid : nil)
                if verified { self.chatStore.replayPendingReads() }
            } else {
                self.mediaContext?.setNetworkAuthorized(false)
                self.mediaContext?.clearMemoryCache()
                self.mediaContext = nil
                self.chatStore.displayPreferences.activate(uid: nil)
                self.chatStore.currentUserProfile = nil
                self.realtimeCoordinator.setSession(uid: nil)
                if case .signedOut = state { self.notifications.setSession(uid: nil) }
            }
        }
        pathObservation = connectivity.$snapshot.sink { [weak self, weak outgoingQueue] path in
            guard let self, let outgoingQueue, path.status != self.lastPathStatus else { return }
            let recoveryHint = path.canAttempt
                && (path.status == .satisfied || self.lastPathStatus == .unsatisfied)
            self.lastPathStatus = path.status
            self.sessionModel.setNetworkOpportunity(path.canAttempt)
            outgoingQueue.setNetworkReachable(path.canAttempt)
            self.realtimeCoordinator.setNetworkOpportunity(path.canAttempt, restored: recoveryHint)
            if recoveryHint {
                self.sessionModel.retryValidationIfNeeded()
                outgoingQueue.resynchronizePublications()
                self.chatStore.replayPendingReads()
            }
        }
        sessionModel.bootstrap()
    }
}
