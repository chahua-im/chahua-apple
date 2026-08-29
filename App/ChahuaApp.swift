//
//  ChahuaApp.swift
//  chahua-ios
//

import SwiftUI

@main
struct ChahuaApp: App {
    private let compositionRoot: AppCompositionRoot

    init() {
        compositionRoot = AppCompositionRoot(apiConfiguration: AppConfiguration.apiConfiguration)
    }

    var body: some Scene {
        WindowGroup {
            compositionRoot
        }
    }
}
