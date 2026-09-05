import SwiftUI

struct AvatarView: View {
    let url: URL?
    let displayName: String
    @ScaledMetric(relativeTo: .body) private var scaledDiameter: CGFloat = 40

    init(url: URL?, displayName: String, diameter: CGFloat = 40) {
        self.url = url
        self.displayName = displayName
        _scaledDiameter = ScaledMetric(wrappedValue: diameter, relativeTo: .body)
    }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
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
        Text(initials)
            .font(.system(size: scaledDiameter * 0.36, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: scaledDiameter, height: scaledDiameter)
            .background(fallbackColor)
    }

    private var initials: String {
        String(displayName.prefix(2)).uppercased()
    }

    private var fallbackColor: Color {
        var hash: Int32 = 0
        for scalar in displayName.unicodeScalars {
            hash = (hash &<< 5) &- hash &+ Int32(truncatingIfNeeded: scalar.value)
        }
        let hue = Double((hash &* 137) % 360)
        return Color(
            hue: (hue < 0 ? hue + 360 : hue) / 360,
            saturation: 0.55 / 0.775,
            brightness: 0.775
        )
    }
}
