import ChahuaAPI
import SwiftUI

struct AppRootView: View {
    @ObservedObject var model: AuthSessionModel
    @ObservedObject var chatStore: ChatStore
    let mediaContext: AppMediaContext
    let realtimeCoordinator: RealtimeCoordinator
    let notifications: PushNotificationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()
    @State private var pendingURL: URL?
    var body: some View {
        Group {
            switch model.state {
            case .bootstrapping:
                if model.isSlow {
                    ChahuaRecoverableErrorView(
                        title: "Connection is taking longer than usual",
                        message: "Retry to start a new connection attempt.",
                        retryTitle: "Retry", onRetry: model.retry)
                } else {
                    ChahuaLoadingView(title: "Restoring session")
                }
            case .signedOut(let reason):
                AuthLoginView(model: model, reason: reason)
            case .authenticated(let me):
                AuthenticatedShell(
                    chatStore: chatStore,
                    notifications: notifications,
                    notificationSceneID: sceneID,
                    me: me,
                    isSigningOut: model.isSubmitting,
                    onSignOut: { Task { await model.logout() } },
                    pendingURL: $pendingURL
                )
                .modifier(ImageDetailPresentation())
                .id(me.uid)
                .environment(\.mediaContext, mediaContext)
            case .restorationFailed(let failure):
                ChahuaRecoverableErrorView(
                    title: failure.title,
                    message: failure.message,
                    retryTitle: "Retry", onRetry: model.retry)
            }
        }
        .onOpenURL { pendingURL = $0 }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            pendingURL = activity.webpageURL
        }
        .onAppear {
            realtimeCoordinator.setSceneActive(id: sceneID, active: scenePhase == .active)
            notifications.setSceneActive(id: sceneID, active: scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            realtimeCoordinator.setSceneActive(id: sceneID, active: phase == .active)
            notifications.setSceneActive(id: sceneID, active: phase == .active)
        }
        .onDisappear {
            realtimeCoordinator.removeScene(id: sceneID)
            notifications.removeScene(id: sceneID)
        }
    }
}

extension AuthStartupFailure {
    fileprivate var title: LocalizedStringKey {
        switch self {
        case .network: "Connection unavailable"
        case .server: "Chahua is temporarily unavailable"
        case .unknown: "Couldn’t restore your session"
        }
    }

    fileprivate var message: LocalizedStringKey {
        switch self {
        case .network: "Check your connection and try again."
        case .server: "The service is temporarily unavailable. Try again."
        case .unknown: "An unexpected error occurred. Your saved sign-in has been kept; try again."
        }
    }
}
