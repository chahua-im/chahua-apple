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
                tracedImage(for: url)
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

    private func tracedImage(for url: URL) -> KFImage {
        let image = KFImage(url)
        guard ScrollPerformanceTrace.isRequested else { return image }
        return image.onSuccess { result in
            switch result.cacheType {
            case .memory: ScrollPerformanceTrace.event("Image.LoadMemory")
            case .disk: ScrollPerformanceTrace.event("Image.LoadDisk")
            case .none: ScrollPerformanceTrace.event("Image.LoadUncached")
            }
        }
    }

    private func cachedImage(for url: URL) -> KFCrossPlatformImage? {
        let trace = ScrollPerformanceTrace.begin("Image.MemoryLookup")
        defer { ScrollPerformanceTrace.end("Image.MemoryLookup", trace) }
        let image = (mediaContext?.cache ?? .default).retrieveImageInMemoryCache(
            forKey: url.absoluteString,
            options: [.processor(processor), .scaleFactor(1)]
        )
        ScrollPerformanceTrace.event(image == nil ? "Image.MemoryMiss" : "Image.MemoryHit")
        return image
    }
}

func swiftUIImage(_ image: KFCrossPlatformImage) -> Image {
    #if os(macOS)
        Image(nsImage: image)
    #else
        Image(uiImage: image)
    #endif
}
