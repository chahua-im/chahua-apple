import ChahuaAPI
import SwiftUI

struct AppCompositionRoot: View {
    @StateObject private var sessionModel: AuthSessionModel

    init(apiConfiguration: ChahuaConfiguration) {
        let tokenStorage = KeychainTokenStorage()
        let apiClient = ChahuaClient(configuration: apiConfiguration)
        _sessionModel = StateObject(wrappedValue: AuthSessionModel(
            apiClient: apiClient,
            credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: tokenStorage
        ))
    }

    init(
        apiClient: any ChahuaAPIClient,
        credentialLoginClient: any CredentialLoginProviding,
        tokenStorage: any SessionTokenStorage
    ) {
        _sessionModel = StateObject(wrappedValue: AuthSessionModel(
            apiClient: apiClient,
            credentialLoginClient: credentialLoginClient,
            tokenStorage: tokenStorage
        ))
    }

    var body: some View { ContentView(model: sessionModel) }
}
