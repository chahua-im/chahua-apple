import ChahuaAPI
import SwiftUI

struct AppRootView: View {
    @ObservedObject var model: AuthSessionModel
    @ObservedObject var chatStore: ChatStore
    let mediaContext: AppMediaContext
    let realtimeCoordinator: RealtimeCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()
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
        .onAppear { realtimeCoordinator.setSceneActive(id: sceneID, active: scenePhase == .active) }
        .onChange(of: scenePhase) { phase in
            realtimeCoordinator.setSceneActive(id: sceneID, active: phase == .active)
        }
        .onDisappear { realtimeCoordinator.removeScene(id: sceneID) }
    }
}
