import ChahuaAPI
import Combine
import Foundation

@MainActor
final class AppCompositionRoot {
    let sessionModel: AuthSessionModel
    let chatStore: ChatStore
    let mediaContext: AppMediaContext
    let realtimeCoordinator: RealtimeCoordinator
    private var sessionObservation: AnyCancellable?

    convenience init(apiConfiguration: ChahuaConfiguration) {
        let client = ChahuaClient(configuration: apiConfiguration)
        self.init(
            apiClient: client,
            realtimeProvider: client,
            credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: KeychainTokenStorage(),
            mediaDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("app.chahua.chat/MediaCache", isDirectory: true),
            mediaNamespace: apiConfiguration.baseURL.absoluteString,
            localStoreFactory: { uid in
                try await Task.detached {
                    let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    let directory = LocalStorageScope(apiBaseURL: apiConfiguration.baseURL, userID: uid).directory(under: root)
                    return try ChahuaLocalStore(directory: directory)
                }.value
            }
        )
    }

    init(
        apiClient: any ChahuaAPIClient,
        realtimeProvider: any RealtimeConnectionProviding,
        credentialLoginClient: any CredentialLoginProviding,
        tokenStorage: any SessionTokenStorage,
        mediaDirectory: URL? = nil,
        mediaNamespace: String = "injected",
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
        let outgoingQueue = OutgoingMessageQueue(apiClient: apiClient, localStoreFactory: localStoreFactory, onInvalidToken: invalidToken)
        chatStore = ChatStore(apiClient: apiClient, outgoingQueue: outgoingQueue, onInvalidToken: invalidToken)
        mediaContext = AppMediaContext(rootDirectory: mediaDirectory, namespace: mediaNamespace)
        realtimeCoordinator = RealtimeCoordinator(provider: realtimeProvider, store: chatStore, onInvalidToken: invalidToken)
        sessionObservation = sessionModel.$state.sink { [weak self] state in
            guard let self else { return }
            if case .authenticated(let me) = state {
                self.chatStore.currentUserProfile = me
                self.mediaContext.activate(uid: me.uid)
                self.realtimeCoordinator.setSession(uid: me.uid)
            } else {
                self.chatStore.currentUserProfile = nil
                self.mediaContext.activate(uid: nil)
                self.realtimeCoordinator.setSession(uid: nil)
            }
        }
        sessionModel.bootstrap()
    }
}
