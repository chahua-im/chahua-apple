//
//  ContentView.swift
//  chahua-ios
//

import ChahuaAPI
import SwiftUI

struct ContentView: View {
    private let apiClient: any ChahuaAPIClient

    init(apiClient: any ChahuaAPIClient) {
        self.apiClient = apiClient
    }

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
    }
}

