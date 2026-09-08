import ChahuaAPI
import Foundation
import SwiftUI

struct AppCompositionRoot: View {
    @StateObject private var sessionModel: AuthSessionModel
    @StateObject private var chatStore: ChatStore
    @StateObject private var mediaContext: AppMediaContext

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
        _mediaContext = StateObject(wrappedValue: AppMediaContext(
            rootDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("app.chahua.chat/MediaCache", isDirectory: true),
            namespace: apiConfiguration.baseURL.absoluteString
        ))
    }

    init(
        apiClient: any ChahuaAPIClient,
        credentialLoginClient: any CredentialLoginProviding,
        tokenStorage: any SessionTokenStorage,
        mediaDirectory: URL? = nil
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
        _mediaContext = StateObject(wrappedValue: AppMediaContext(
            rootDirectory: mediaDirectory,
            namespace: "injected"
        ))
    }

    var body: some View {
        AppRootView(model: sessionModel, chatStore: chatStore, mediaContext: mediaContext)
    }
}
