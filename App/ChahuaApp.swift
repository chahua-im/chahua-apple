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
        if NSClassFromString("XCTestCase") != nil {
            compositionRoot = nil
        } else {
            compositionRoot = AppCompositionRoot(apiConfiguration: AppConfiguration.apiConfiguration)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let compositionRoot {
                compositionRoot
            } else {
                Color.clear
            }
        }
    }
}
