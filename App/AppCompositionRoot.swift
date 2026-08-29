//
//  AppCompositionRoot.swift
//  chahua-ios
//

import Foundation
import ChahuaAPI
import SwiftUI

struct AppCompositionRoot: View {
    private let apiClient: any ChahuaAPIClient

    init(apiConfiguration: ChahuaConfiguration) {
        apiClient = ChahuaClient(configuration: apiConfiguration)
    }

    var body: some View {
        ContentView(apiClient: apiClient)
    }
}

#Preview {
    AppCompositionRoot(
        apiConfiguration: ChahuaConfiguration(baseURL: URL(string: "https://example.com")!)
    )
}
