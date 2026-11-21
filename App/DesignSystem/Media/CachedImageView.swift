import Kingfisher
import SwiftUI

struct CachedImageView<Content: View>: View {
    let url: URL?
    var thumbnailPixelSize: CGSize? = nil
    @ViewBuilder var content: (RemoteImagePhase) -> Content
    @Environment(\.mediaContext) private var mediaContext

    var body: some View {
        if let url, let mediaContext {
            MediaPolicyView(context: mediaContext) { policy in
                image(for: url, context: mediaContext, cacheOnly: !policy.allowsNetwork())
            }
        } else {
            content(url == nil ? .empty : .failure)
        }
    }

    @ViewBuilder private func image(
        for url: URL, context: AppMediaContext, cacheOnly: Bool
    ) -> some View {
        if let image = cachedImage(for: url, cache: context.cache) {
            content(.success(swiftUIImage(image)))
        } else {
            tracedImage(for: url)
                .setProcessor(processor)
                .scaleFactor(1)
                .targetCache(context.cache)
                .downloader(context.downloader)
                .onlyFromCache(cacheOnly)
                .cacheOriginalImage()
                .cancelOnDisappear(true)
                .placeholder { content(cacheOnly ? .failure : .empty) }
                .onFailureView { content(.failure) }
                .contentConfigure { image, isLoaded in
                    if isLoaded {
                        content(.success(image))
                    }
                }
                .id(
                    ImageRequest(url: url, context: ObjectIdentifier(context), cacheOnly: cacheOnly)
                )
        }
    }

    private struct ImageRequest: Hashable {
        let url: URL
        let context: ObjectIdentifier
        let cacheOnly: Bool
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

    private func cachedImage(for url: URL, cache: ImageCache) -> KFCrossPlatformImage? {
        let trace = ScrollPerformanceTrace.begin("Image.MemoryLookup")
        defer { ScrollPerformanceTrace.end("Image.MemoryLookup", trace) }
        let image = cache.retrieveImageInMemoryCache(
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
