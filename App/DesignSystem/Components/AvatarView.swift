import SwiftUI

struct AvatarView: View {
    let url: URL?
    let displayName: String
    @ScaledMetric(relativeTo: .body) private var scaledDiameter: CGFloat = 40
    @Environment(\.displayScale) private var displayScale

    init(url: URL?, displayName: String, diameter: CGFloat = 40) {
        self.url = url
        self.displayName = displayName
        _scaledDiameter = ScaledMetric(wrappedValue: diameter, relativeTo: .body)
    }

    var body: some View {
        Group {
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
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: scaledDiameter, height: scaledDiameter)
        .clipShape(Circle())
        .accessibilityLabel(Text("Avatar for \(displayName)"))
    }

    private var fallback: some View {
        AvatarPlaceholder(displayName: displayName, diameter: scaledDiameter)
    }
}
