import ChahuaAPI
import Combine
import Foundation

@MainActor
final class AppCompositionRoot {
    let sessionModel: AuthSessionModel
    let chatStore: ChatStore
    let mediaContext: AppMediaContext
    let realtimeCoordinator: RealtimeCoordinator
    let notifications: PushNotificationCoordinator
    let localStorage: AccountLocalStoreOwner
    private var chatObservation: AnyCancellable?

    convenience init(apiConfiguration: ChahuaConfiguration) {
        let client = ChahuaClient(configuration: apiConfiguration)
        self.init(
            apiClient: client,
            realtimeProvider: client,
            credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: KeychainTokenStorage(),
            mediaNamespace: apiConfiguration.baseURL.absoluteString,
            localStoreFactory: { uid in
                try await Task.detached {
                    let root = try FileManager.default.url(
                        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                        create: true)
                    let directory = LocalStorageScope(
                        apiBaseURL: apiConfiguration.baseURL, userID: uid
                    ).directory(under: root)
                    return try ChahuaLocalStore(directory: directory, userID: uid)
                }.value
            }
        )
    }

    init(
        apiClient: any ChahuaAPIClient,
        realtimeProvider: any RealtimeConnectionProviding,
        credentialLoginClient: any CredentialLoginProviding,
        tokenStorage: any SessionTokenStorage,
        mediaNamespace: String = "injected",
        preferenceDefaults: UserDefaults = .standard,
        localStoreFactory: @escaping @Sendable (Int32) async throws -> ChahuaLocalStore
    ) {
        let sessionModel = AuthSessionModel(
            apiClient: apiClient,
            credentialLoginClient: credentialLoginClient,
            tokenStorage: tokenStorage
        )
        self.sessionModel = sessionModel
        let invalidToken: @MainActor @Sendable () async -> Void = { [weak sessionModel] in
            await sessionModel?.sessionDidExpire()
        }
        let localStorage = AccountLocalStoreOwner(factory: localStoreFactory)
        self.localStorage = localStorage
        let outgoingQueue = OutgoingMessageQueue(
            apiClient: apiClient, storage: localStorage, onInvalidToken: invalidToken,
            monitorNetwork: true
        )
        chatStore = ChatStore(
            apiClient: apiClient, outgoingQueue: outgoingQueue,
            displayPreferences: ConversationDisplayPreferences(
                defaults: preferenceDefaults, namespace: mediaNamespace),
            onInvalidToken: invalidToken)
        mediaContext = AppMediaContext(namespace: mediaNamespace)
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
        sessionModel.prepareForSignOut = {
            [weak notifications, weak chatStore, weak outgoingQueue] in
            guard let notifications, let chatStore, let outgoingQueue else {
                throw CancellationError()
            }
            chatStore.drafts.fenceForSignOut()
            outgoingQueue.fenceForSignOut()
            do {
                try await notifications.prepareForSignOut()
            } catch {
                await outgoingQueue.resumeAfterUnregisterFailure()
                chatStore.drafts.resumeAfterUnregisterFailure()
                throw error
            }
            try await outgoingQueue.purgeForSignOut()
        }
        chatStore.onNotificationRead = { [weak notifications] conversation, messageID in
            notifications?.didRead(conversation: conversation, through: messageID)
        }
        chatObservation = chatStore.$state.sink { [weak notifications] state in
            notifications?.synchronizeReadState(state)
        }
        sessionModel.willTransitionSession = { [weak self] state in
            guard let self else { return }
            self.mediaContext.clearMemoryCache()
            if case .authenticated(let me) = state {
                // Session replacement resets account-owned stores; bind the new
                // profile only after that reset, before any feature can load.
                self.realtimeCoordinator.setSession(uid: me.uid)
                self.chatStore.displayPreferences.activate(uid: me.uid)
                self.chatStore.currentUserProfile = me
                self.notifications.setSession(uid: me.uid)
            } else {
                self.chatStore.displayPreferences.activate(uid: nil)
                self.chatStore.currentUserProfile = nil
                self.realtimeCoordinator.setSession(uid: nil)
                if case .signedOut = state { self.notifications.setSession(uid: nil) }
            }
        }
        sessionModel.bootstrap()
    }
}
