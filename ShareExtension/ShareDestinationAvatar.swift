import SwiftUI

/// Mirrors the conversation list: peer/group avatar with a root-author badge for
/// group threads or a conversation badge for DM threads. Image loading stays local
/// to the extension; the main app's account-owned media cache is not opened here.
struct ShareDestinationAvatar: View {
    let destination: ShareDestination
    var diameter: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let secondarySize = max(16, (diameter * 0.55).rounded())
        ShareAvatarImage(
            url: destination.avatarURL, displayName: destination.avatarName, diameter: diameter
        )
        .overlay(alignment: .topTrailing) {
            if let badge = destination.avatarBadge {
                Group {
                    switch badge {
                    case .thread:
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(
                                width: secondarySize * scale * 2 / 3,
                                height: secondarySize * scale * 2 / 3
                            )
                            .foregroundStyle(.white)
                            .frame(width: secondarySize * scale, height: secondarySize * scale)
                            .background(Color.accentColor, in: Circle())
                    case .person(let url, let name):
                        ShareAvatarImage(url: url, displayName: name, diameter: secondarySize)
                    }
                }
                .background { Circle().fill(.background).padding(-2) }
                .offset(x: 2, y: -2)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct ShareAvatarImage: View {
    let url: URL?
    let displayName: String
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 48

    init(url: URL?, displayName: String, diameter: CGFloat) {
        self.url = url
        self.displayName = displayName
        _diameter = ScaledMetric(wrappedValue: diameter, relativeTo: .body)
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                AvatarPlaceholder(displayName: displayName, diameter: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .accessibilityLabel(Text("Avatar for \(displayName)"))
    }
}
