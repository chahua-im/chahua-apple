import SwiftUI

struct ChahuaLoadingView: View {
    let title: LocalizedStringKey
    var body: some View { StateMessage(title: title, message: nil, systemImage: "hourglass", action: nil) }
}

struct ChahuaEmptyStateView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String
    var body: some View { StateMessage(title: title, message: message, systemImage: systemImage, action: nil) }
}

struct ChahuaRecoverableErrorView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let retryTitle: LocalizedStringKey
    let onRetry: () -> Void
    var body: some View {
        StateMessage(title: title, message: message, systemImage: "exclamationmark.triangle", action: (retryTitle, onRetry))
    }
}

private struct StateMessage: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let systemImage: String
    let action: (LocalizedStringKey, () -> Void)?

    var body: some View {
        VStack(spacing: ChahuaTheme.Spacing.medium) {
            Image(systemName: systemImage).font(.title).foregroundStyle(ChahuaTheme.secondaryText)
            Text(title).font(.headline)
            if let message { Text(message).foregroundStyle(ChahuaTheme.secondaryText).multilineTextAlignment(.center) }
            if let action { Button(action.0, action: action.1).buttonStyle(.bordered) }
        }
        .padding(ChahuaTheme.Spacing.xLarge)
        .frame(maxWidth: .infinity)
    }
}
