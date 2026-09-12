import Kingfisher
import SwiftUI

struct CachedImageView<Content: View>: View {
    let url: URL?
    var thumbnailPixelSize: CGSize? = nil
    @ViewBuilder var content: (RemoteImagePhase) -> Content
    @Environment(\.mediaContext) private var mediaContext

    var body: some View {
        if let url {
            if let image = cachedImage(for: url) {
                content(.success(swiftUIImage(image)))
            } else {
                KFImage(url)
                    .setProcessor(processor)
                    .scaleFactor(1)
                    .targetCache(mediaContext?.cache ?? .default)
                    .downloader(mediaContext?.downloader ?? .default)
                    .cacheOriginalImage()
                    .placeholder { content(.empty) }
                    .onFailureView { content(.failure) }
                    .contentConfigure { image, isLoaded in
                        if isLoaded {
                            content(.success(image))
                        }
                    }
            }
        } else {
            content(.empty)
        }
    }

    private var processor: any ImageProcessor {
        if let thumbnailPixelSize {
            DownsamplingImageProcessor(size: thumbnailPixelSize)
        } else {
            DefaultImageProcessor.default
        }
    }

    private func cachedImage(for url: URL) -> KFCrossPlatformImage? {
        (mediaContext?.cache ?? .default).retrieveImageInMemoryCache(
            forKey: url.absoluteString,
            options: [.processor(processor), .scaleFactor(1)]
        )
    }
}

func swiftUIImage(_ image: KFCrossPlatformImage) -> Image {
#if os(macOS)
    Image(nsImage: image)
#else
    Image(uiImage: image)
#endif
}
