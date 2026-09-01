import ChahuaAPI
import SwiftUI

struct AppCompositionRoot: View {
    @StateObject private var sessionModel: AuthSessionModel
    @StateObject private var chatStore: ChatStore

    init(apiConfiguration: ChahuaConfiguration) {
        let tokenStorage = KeychainTokenStorage()
        let apiClient = ChahuaClient(configuration: apiConfiguration)
        let sessionModel = AuthSessionModel(
            apiClient: apiClient,
            credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: tokenStorage
        )
        _sessionModel = StateObject(wrappedValue: sessionModel)
        _chatStore = StateObject(wrappedValue: ChatStore(
            apiClient: apiClient,
            onInvalidToken: { [weak sessionModel] in await sessionModel?.sessionDidExpire() }
        ))
    }

    init(
        apiClient: any ChahuaAPIClient,
        credentialLoginClient: any CredentialLoginProviding,
        tokenStorage: any SessionTokenStorage
    ) {
        let sessionModel = AuthSessionModel(
            apiClient: apiClient,
            credentialLoginClient: credentialLoginClient,
            tokenStorage: tokenStorage
        )
        _sessionModel = StateObject(wrappedValue: sessionModel)
        _chatStore = StateObject(wrappedValue: ChatStore(
            apiClient: apiClient,
            onInvalidToken: { [weak sessionModel] in await sessionModel?.sessionDidExpire() }
        ))
    }

    var body: some View { AppRootView(model: sessionModel, chatStore: chatStore) }
}
