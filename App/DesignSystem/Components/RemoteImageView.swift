import SwiftUI

enum RemoteImagePhase {
    case empty
    case success(Image)
    case failure
}

struct RemoteImageView: View {
    let url: URL?
    let phaseOverride: RemoteImagePhase?

    init(url: URL?, phaseOverride: RemoteImagePhase? = nil) {
        self.url = url
        self.phaseOverride = phaseOverride
    }

    var body: some View {
        if let phaseOverride { content(phaseOverride) }
        else if let url { AsyncImage(url: url) { phase in
            switch phase {
            case .empty: content(.empty)
            case .success(let image): content(.success(image))
            case .failure: content(.failure)
            @unknown default: content(.failure)
            }
        } }
        else { content(.failure) }
    }

    @ViewBuilder private func content(_ phase: RemoteImagePhase) -> some View {
        switch phase {
        case .empty: ProgressView()
        case .success(let image): image.resizable().scaledToFill()
        case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }
}

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
        RemoteImageView(url: url)
            .overlay { if url == nil { fallback } }
            .frame(width: scaledDiameter, height: scaledDiameter)
            .background(ChahuaTheme.secondaryBackground)
            .clipShape(Circle())
            .accessibilityLabel(Text("Avatar for \(displayName)"))
    }

    @ViewBuilder private var fallback: some View {
        let initials = displayName.split(whereSeparator: \.isWhitespace)
        if let first = initials.first {
            Text(String(first.prefix(1) + (initials.count > 1 ? initials.last!.prefix(1) : "")).uppercased())
                .font(.headline)
        } else { Image(systemName: "person.fill") }
    }
}
