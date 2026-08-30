import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AuthSessionModel

    var body: some View {
        Group {
            switch model.state {
            case .bootstrapping:
                ChahuaLoadingView(title: "Restoring session")
            case .signedOut:
                AuthLoginView(model: model)
            case .authenticated(let me):
                AuthenticatedAccountView(model: model, me: me)
            case .networkUnavailable:
                ChahuaRecoverableErrorView(
                    title: "Connection unavailable",
                    message: "Check your connection and try again.",
                    retryTitle: "Try again",
                    onRetry: model.retry
                )
            }
        }
        .task { model.bootstrap() }
    }
}
