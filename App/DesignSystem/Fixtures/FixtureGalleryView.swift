import SwiftUI

struct FixtureGalleryView: View {
    private let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)
    @State private var layoutCache = TimelineLayoutCache()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @ScaledMetric(relativeTo: .body) private var bodySize = TimelineFixtureTypography.body
    @ScaledMetric(relativeTo: .caption) private var captionSize = TimelineFixtureTypography.caption
    @ScaledMetric(relativeTo: .caption2) private var caption2Size = TimelineFixtureTypography.caption2
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
            List {
                #if DEBUG
                Section("Native timeline verification") {
                    NavigationLink("Images, replies, threads and delivery states") {
                        TimelineBubbleFixtureView()
                    }
                }
                Section("Text bubbles") {
                    VStack(spacing: 0) {
                        ForEach(DesignSystemFixtures.textBubbleRows) { row in
                            fixtureRow(row, width: geometry.size.width)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                }
                Section("Direct chat text bubbles") {
                    VStack(spacing: 0) {
                        ForEach(DesignSystemFixtures.directTextBubbleRows) { row in
                            fixtureRow(row, width: geometry.size.width)
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
            .listStyle(.plain)
            }
            .navigationTitle("Component gallery")
        }
    }

    private func fixtureRow(_ row: TimelineRow, width: CGFloat) -> some View {
        let environment = TimelineLayoutEnvironment.current(
            timelineWidth: width, displayScale: displayScale,
            bodySize: bodySize, captionSize: captionSize, caption2Size: caption2Size,
            avatarSize: avatarSize, locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!,
            layoutDirection: layoutDirection
        )
        let presentation = TimelineRowPresentation.make(row: row, currentUserProfile: nil, currentUserID: nil, isThreadTimeline: false, environment: environment)
        let layout = layoutCache.layout(for: presentation, environment: environment)
        return TimelineBubbleView(presentation: presentation, layout: layout, context: .init())
            .frame(width: layout.size.width, height: layout.size.height)
    }
}

private enum TimelineFixtureTypography {
    #if os(macOS)
    static let body = NSFont.preferredFont(forTextStyle: .body).pointSize
    static let caption = NSFont.preferredFont(forTextStyle: .caption1).pointSize
    static let caption2 = NSFont.preferredFont(forTextStyle: .caption2).pointSize
    #else
    static let body = UIFont.preferredFont(forTextStyle: .body).pointSize
    static let caption = UIFont.preferredFont(forTextStyle: .caption1).pointSize
    static let caption2 = UIFont.preferredFont(forTextStyle: .caption2).pointSize
    #endif
}

#Preview("English") { FixtureGalleryView().environment(\.locale, Locale(identifier: "en")) }
#Preview("Simplified Chinese") { FixtureGalleryView().environment(\.locale, Locale(identifier: "zh-Hans")) }
#Preview("Traditional Chinese") { FixtureGalleryView().environment(\.locale, Locale(identifier: "zh-Hant")) }
#Preview("Light text bubbles") { FixtureGalleryView().preferredColorScheme(.light) }
#Preview("Dark text bubbles") { FixtureGalleryView().preferredColorScheme(.dark) }
#Preview("Accessible text bubbles") { FixtureGalleryView().environment(\.dynamicTypeSize, .accessibility3) }
