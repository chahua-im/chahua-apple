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

