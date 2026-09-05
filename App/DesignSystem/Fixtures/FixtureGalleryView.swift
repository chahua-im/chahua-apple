import SwiftUI

struct FixtureGalleryView: View {
    private let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)

    var body: some View {
        NavigationStack {
            List {
                #if DEBUG
                Section("Text bubbles") {
                    VStack(spacing: 0) {
                        ForEach(DesignSystemFixtures.textBubbleRows) { row in
                            TimelineBubbleView(row: row, context: .init())
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                }
                Section("Direct chat text bubbles") {
                    VStack(spacing: 0) {
                        ForEach(DesignSystemFixtures.directTextBubbleRows) { row in
                            TimelineBubbleView(row: row, context: .init())
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                }
                #endif
                Section("Form controls") {
                    ChahuaTextField(title: "Username", prompt: "Username", text: .constant("fixture-user"))
                    ChahuaSecureField(title: "Password", prompt: "Password", text: .constant(""), validationMessage: "Invalid credentials.")
                    ChahuaPrimaryButton(title: "Sign in", isWorking: false, action: {})
                    ChahuaPrimaryButton(title: "Signing in", isWorking: true, action: {})
                }
                Section("Content states") {
                    ChahuaLoadingView(title: "Loading")
                    ChahuaEmptyStateView(title: "No content", message: "There is nothing to show yet.", systemImage: "tray")
                    ChahuaRecoverableErrorView(title: "Something went wrong", message: "Try again when you are connected.", retryTitle: "Try again", onRetry: {})
                }
                Section("Avatars and images") {
                    AvatarView(url: nil, displayName: "Ada Lovelace")
                    RemoteImageView(url: nil, phaseOverride: .empty).frame(height: 44)
                    RemoteImageView(url: nil, phaseOverride: .failure).frame(height: 44)
                }
                Section("Timestamps") {
                    TimestampView(date: fixtureDate, style: .time)
                    TimestampView(date: fixtureDate, style: .date)
                    TimestampView(date: fixtureDate, style: .dateTime)
                    TimestampView(date: fixtureDate, style: .relative)
                }
            }
            .navigationTitle("Component gallery")
        }
    }
}

#Preview("English") { FixtureGalleryView().environment(\.locale, Locale(identifier: "en")) }
#Preview("Simplified Chinese") { FixtureGalleryView().environment(\.locale, Locale(identifier: "zh-Hans")) }
#Preview("Traditional Chinese") { FixtureGalleryView().environment(\.locale, Locale(identifier: "zh-Hant")) }
#Preview("Light text bubbles") { FixtureGalleryView().preferredColorScheme(.light) }
#Preview("Dark text bubbles") { FixtureGalleryView().preferredColorScheme(.dark) }
#Preview("Accessible text bubbles") { FixtureGalleryView().environment(\.dynamicTypeSize, .accessibility3) }
