import SwiftUI

/// Identical initials and deterministic color in the app and Share extension.
struct AvatarPlaceholder: View {
    let displayName: String
    let diameter: CGFloat

    var body: some View {
        Text(String(displayName.prefix(2)).uppercased())
            .font(.system(size: diameter * 0.36, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(color)
    }

    private var color: Color {
        var hash: Int32 = 0
        for scalar in displayName.unicodeScalars {
            hash = (hash &<< 5) &- hash &+ Int32(truncatingIfNeeded: scalar.value)
        }
        let hue = Double((hash &* 137) % 360)
        return Color(
            hue: (hue < 0 ? hue + 360 : hue) / 360,
            saturation: 0.55 / 0.775,
            brightness: 0.775)
    }
}
