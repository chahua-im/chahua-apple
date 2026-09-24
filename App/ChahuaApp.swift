//
//  ChahuaApp.swift
//  chahua-ios
//

import SwiftUI

@main
struct ChahuaApp: App {
    #if os(iOS)
        @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #else
        @NSApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #endif
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system
        .rawValue
    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }

    private let compositionRoot: AppCompositionRoot?

    init() {
        // Hosted tests and SwiftUI previews must not start production services or
        // contend with the running app for its exclusive media-cache lock.
        #if DEBUG || TIMELINE_PROFILING
            if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
                || ProcessInfo.processInfo.arguments.contains("-fixture-gallery")
                || ProcessInfo.processInfo.arguments.contains("-bubble-timeline")
            {
                compositionRoot = nil
                return
            }
        #endif
        if NSClassFromString("XCTestCase") != nil {
            compositionRoot = nil
        } else {
            compositionRoot = AppCompositionRoot(
                apiConfiguration: AppConfiguration.apiConfiguration)
        }
        pushDelegate.coordinator = compositionRoot?.notifications
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-fixture-gallery") {
                    FixtureGalleryView()
                } else {
                    appRoot
                }
            #else
                appRoot
            #endif
        }
        .environment(\.locale, appLanguage.locale)
        #if os(macOS)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
        #endif
    }

    @ViewBuilder
    private var appRoot: some View {
        #if DEBUG || TIMELINE_PROFILING
            if ProcessInfo.processInfo.arguments.contains("-bubble-timeline") {
                TimelineBubbleFixtureView()
                    .modifier(ImageDetailPresentation())
            } else {
                productionRoot
            }
        #else
            productionRoot
        #endif
    }

    @ViewBuilder
    private var productionRoot: some View {
        if let compositionRoot {
            AppRootView(
                model: compositionRoot.sessionModel,
                chatStore: compositionRoot.chatStore,
                mediaContext: compositionRoot.mediaContext,
                realtimeCoordinator: compositionRoot.realtimeCoordinator,
                notifications: compositionRoot.notifications
            )
            #if os(macOS)
                .frame(minWidth: ChatSplitMetrics.splitThreshold)
            #endif
        } else {
            Color.clear
                #if os(macOS)
                    .frame(minWidth: ChatSplitMetrics.splitThreshold)
                #endif
        }
    }
}
