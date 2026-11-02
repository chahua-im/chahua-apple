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
        #if os(macOS)
            .background {
                MacActivityWindowMarker(
                    monitor: realtimeCoordinator.macActivityMonitor, sceneID: sceneID
                )
                .frame(width: 0, height: 0)
            }
        #endif
        .onOpenURL { pendingURL = $0 }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            pendingURL = activity.webpageURL
        }
        .onAppear {
            #if os(iOS)
                reportSceneActivity(scenePhase == .active)
            #endif
            notifications.setSceneActive(id: sceneID, active: scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
                reportSceneActivity(phase == .active)
            #endif
            notifications.setSceneActive(id: sceneID, active: phase == .active)
        }
        .onDisappear {
            #if os(iOS)
                let id = sceneID
                DispatchQueue.main.async { [weak realtimeCoordinator] in
                    realtimeCoordinator?.removeScene(id: id)
                }
            #endif
            notifications.removeScene(id: sceneID)
        }
    }

    #if os(iOS)
        private func reportSceneActivity(_ active: Bool) {
            // Scene callbacks can coincide with native hierarchy reconciliation.
            // Keep lifecycle-driven store publications outside that transaction.
            let id = sceneID
            DispatchQueue.main.async { [weak realtimeCoordinator] in
                realtimeCoordinator?.setSceneActive(id: id, active: active)
            }
        }
    #endif
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
