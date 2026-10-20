import SwiftUI

struct AvatarView: View {
    let url: URL?
    let displayName: String
    let diameter: CGFloat
    @Environment(\.displayScale) private var displayScale

    init(url: URL?, displayName: String, diameter: CGFloat = 40) {
        self.url = url
        self.displayName = displayName
        self.diameter = diameter
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
        .accessibilityLabel(Text("Avatar for \(displayName)"))
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
