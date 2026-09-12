import Kingfisher
import SwiftUI

enum RemoteImagePhase {
    case empty
    case success(Image)
    case failure
}
enum RemoteImageFormat {
    static func isAnimated(contentType: String) -> Bool {
        switch contentType.lowercased().split(separator: ";", maxSplits: 1).first {
        case "image/gif", "image/apng", "image/webp":
            true
        default:
            false
        }
    }
}


struct RemoteImageView: View {
    let url: URL?
    let phaseOverride: RemoteImagePhase?
    let contentMode: SwiftUI.ContentMode
    let animates: Bool
    let showsBlurredBackdrop: Bool
    let thumbnailPixelSize: CGSize?
    @Environment(\.mediaContext) private var mediaContext

    init(
        url: URL?,
        phaseOverride: RemoteImagePhase? = nil,
        contentMode: SwiftUI.ContentMode = .fill,
        animates: Bool = false,
        showsBlurredBackdrop: Bool = false,
        thumbnailPixelSize: CGSize? = nil
    ) {
        self.url = url
        self.phaseOverride = phaseOverride
        self.contentMode = contentMode
        self.animates = animates
        self.showsBlurredBackdrop = showsBlurredBackdrop
        self.thumbnailPixelSize = thumbnailPixelSize
    }

    var body: some View {
        if let phaseOverride {
            staticContent(phaseOverride)
        } else if let url {
            if animates {
                animatedContent(url)
            } else {
                staticImage(url)
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private func staticImage(_ url: URL) -> some View {
        CachedImageView(url: url, thumbnailPixelSize: thumbnailPixelSize) { phase in
            staticContent(phase)
        }
    }

    @ViewBuilder private func staticContent(_ phase: RemoteImagePhase) -> some View {
        switch phase {
        case .empty:
            ProgressView()
        case .failure:
            Image(systemName: "photo").foregroundStyle(.secondary)
        case .success(let image):
            imageContent(backdrop: image) {
                image.resizable().aspectRatio(contentMode: contentMode)
            }
        }
    }

    @ViewBuilder private func animatedContent(_ url: URL) -> some View {
        ZStack {
            CachedImageView(url: url, thumbnailPixelSize: thumbnailPixelSize) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                case .failure:
                    Image(systemName: "photo").foregroundStyle(.secondary)
                case .success(let image):
                    imageContent(backdrop: image) {
                        image.resizable().aspectRatio(contentMode: contentMode)
                    }
                }
            }
            KFAnimatedImage(url)
                .targetCache(mediaContext?.cache ?? .default)
                .downloader(mediaContext?.downloader ?? .default)
                .placeholder { Color.clear }
                .onFailureView { Color.clear }
                .configure { view in
                    #if os(macOS)
                    view.imageScaling = contentMode == .fit ? .scaleProportionallyUpOrDown : .scaleAxesIndependently
                    #else
                    view.contentMode = contentMode == .fit ? .scaleAspectFit : .scaleAspectFill
                    #endif
                }
                .aspectRatio(contentMode: contentMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
    }


    @ViewBuilder private func imageContent<Foreground: View>(
        backdrop: Image,
        @ViewBuilder foreground: () -> Foreground
    ) -> some View {
        if showsBlurredBackdrop {
            foreground()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { blurredBackdrop(backdrop) }
                .clipped()
        } else {
            foreground()
        }
    }

    private func blurredBackdrop(_ image: Image) -> some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                image.resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width + 40, height: geometry.size.height + 40)
                    .blur(radius: 20)
                    .opacity(0.8)
                Color.black.opacity(0.2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
