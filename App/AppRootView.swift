import ChahuaAPI
import SwiftUI

struct AppRootView: View {
    @ObservedObject var model: AuthSessionModel
    @ObservedObject var chatStore: ChatStore
    let mediaContext: AppMediaContext
    var body: some View {
        Group {
            switch model.state {
            case .bootstrapping:
                ChahuaLoadingView(title: "Restoring session")
            case .signedOut:
                AuthLoginView(model: model)
            case .authenticated(let me):
                AuthenticatedShell(
                    chatStore: chatStore,
                    me: me,
                    isSigningOut: model.isSubmitting,
                    onSignOut: { Task { await model.logout() } }
                )
                .environment(\.mediaContext, mediaContext)
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
        .onReceive(model.$state) { state in
            if case .authenticated(let me) = state {
                mediaContext.activate(uid: me.uid)
            } else {
                mediaContext.activate(uid: nil)
                chatStore.reset()
            }
        }
    }
}
