import SwiftUI

struct AvatarView: View {
    let url: URL?
    let displayName: String
    let diameter: CGFloat
    let isOnline: Bool
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.displayScale) private var displayScale

    init(url: URL?, displayName: String, diameter: CGFloat = 40, isOnline: Bool = false) {
        self.url = url
        self.displayName = displayName
        self.diameter = diameter
        self.isOnline = isOnline
    }

    var body: some View {
        AvatarFrame(diameter: diameter) { scaledDiameter in
            if let url {
                CachedImageView(
                    url: url,
                    thumbnailPixelSize: CGSize(
                        width: ceil(scaledDiameter * displayScale),
                        height: ceil(scaledDiameter * displayScale)
                    )
                ) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        AvatarPlaceholder(displayName: displayName, diameter: scaledDiameter)
                    }
                }
            } else {
                AvatarPlaceholder(displayName: displayName, diameter: scaledDiameter)
            }
        }
        // Overlay after the shared circular clip, within its bounds so headers cannot cut it off.
        .overlay(alignment: .bottomTrailing) {
            if isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: diameter * scale * 0.24, height: diameter * scale * 0.24)
                    .overlay {
                        Circle().strokeBorder(.background, lineWidth: diameter * scale * 0.045)
                    }
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text("Avatar for \(displayName)"))
        .accessibilityValue(isOnline ? AppLanguage.localized("Online") : "")
    }
}

/// Image and symbol avatars share the same Dynamic Type scaling and circular bounds.
struct AvatarFrame<Content: View>: View {
    @ScaledMetric(relativeTo: .body) private var scaledDiameter: CGFloat = 40
    private let content: (CGFloat) -> Content

    init(diameter: CGFloat, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        _scaledDiameter = ScaledMetric(wrappedValue: diameter, relativeTo: .body)
        self.content = content
    }

    var body: some View {
        content(scaledDiameter)
            .frame(width: scaledDiameter, height: scaledDiameter)
            .clipShape(Circle())
    }
}
