//
//  ChahuaApp.swift
//  chahua-ios
//

import SwiftUI

@main
struct ChahuaApp: App {
    private let compositionRoot: AppCompositionRoot?

    init() {
        // Hosted unit tests need a platform application/window, not production startup.
        // Do not construct authentication or network dependencies in the XCTest process.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-fixture-gallery")
            || ProcessInfo.processInfo.arguments.contains("-bubble-timeline") {
            compositionRoot = nil
            return
        }
        #endif
        if NSClassFromString("XCTestCase") != nil {
            compositionRoot = nil
        } else {
            compositionRoot = AppCompositionRoot(apiConfiguration: AppConfiguration.apiConfiguration)
        }
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
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }

    @ViewBuilder
    private var appRoot: some View {
        #if DEBUG && os(macOS)
        if ProcessInfo.processInfo.arguments.contains("-bubble-timeline") {
            TimelineBubbleFixtureView()
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
                realtimeCoordinator: compositionRoot.realtimeCoordinator
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
