import CryptoKit
import Foundation
import ImageIO
import Kingfisher
import SwiftUI
import WebKit

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
final class AppMediaContext {
    let cache: ImageCache
    let downloader: ImageDownloader
    let videoCache: VideoFileCache
    lazy var stickerVideoDataStore = WKWebsiteDataStore.nonPersistent()

    convenience init(namespace: String) {
        self.init(
            cache: ImageCache(name: Self.cacheName(namespace: namespace)),
            downloader: .default
        )
    }

    init(cache: ImageCache, downloader: ImageDownloader) {
        self.cache = cache
        self.downloader = downloader
        // A sibling of Kingfisher's directory retains its exact injected/account namespace
        // without letting Kingfisher's cleanup remove a movie currently owned by AVPlayer.
        videoCache = VideoFileCache(
            directory: cache.diskStorage.directoryURL.appendingPathExtension("videos"),
            configuration: downloader.sessionConfiguration)
        cache.memoryStorage.config.totalCostLimit = 64 * 1_024 * 1_024
        cache.memoryStorage.config.countLimit = 256
        cache.diskStorage.config.sizeLimit = 512 * 1_024 * 1_024
    }

    func clearMemoryCache() {
        cache.clearMemoryCache()
    }

    private static func cacheName(namespace: String) -> String {
        let digest = SHA256.hash(data: Data(namespace.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "app.chahua.chat.images.\(digest)"
    }
}

/// Uses the account's existing bounded cache, not a second decoded-frame cache.
/// The size-independent entry holds only drawable pixels while a resized request
/// is being processed; original media bytes remain in Kingfisher's normal cache.
enum TimelineImageMemory {
    static func firstFrameKey(for url: URL) -> String {
        "app.chahua.timeline.first-frame:\(url.absoluteString)"
    }

    nonisolated static func cgImage(_ image: KFCrossPlatformImage) -> CGImage? {
        #if os(macOS)
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                ?? image.kf.frameSource?.frame(at: 0)
        #else
            return image.cgImage ?? image.images?.first?.cgImage
                ?? image.kf.frameSource?.frame(at: 0)
        #endif
    }

    nonisolated static func image(_ pixels: CGImage) -> KFCrossPlatformImage {
        #if os(macOS)
            NSImage(cgImage: pixels, size: CGSize(width: pixels.width, height: pixels.height))
        #else
            UIImage(cgImage: pixels)
        #endif
    }

    #if os(iOS)
        /// A display boundary, not just CGImage extraction: WebP frame sources can
        /// return compressed/lazy pixels. Call only on background processing or
        /// preparation queues, including for originals and animation first frames.
        nonisolated static func displayReadyFrame(_ image: UIImage, pixels: CGSize?) -> UIImage? {
            if let source = image.kf.frameSource {
                guard let frame = source.frame(at: 0, maxSize: pixels) else { return nil }
                return UIImage(cgImage: frame).preparingForDisplay()
            }
            guard let frame = image.cgImage ?? image.images?.first?.cgImage else { return nil }
            let drawable = UIImage(cgImage: frame)
            if let pixels {
                let maximum = max(pixels.width, pixels.height)
                let factor = min(1, maximum / CGFloat(max(frame.width, frame.height)))
                if factor < 1 {
                    // Unlike DownsamplingImageProcessor's .image path, this does
                    // not encode/decode a full-size PNG just to restore an original.
                    return drawable.preparingThumbnail(
                        of: CGSize(
                            width: CGFloat(frame.width) * factor,
                            height: CGFloat(frame.height) * factor))
                }
            }
            return drawable.preparingForDisplay()
        }
    #endif
}

#if os(iOS)
    /// Keep ImageIO downsampling for bytes, but do not use Kingfisher's .image
    /// downsampling path: it re-encodes the entire original before thumbnailing.
    nonisolated struct TimelineStaticImageProcessor: ImageProcessor {
        let size: CGSize
        var identifier: String { "app.chahua.timeline.native-thumbnail:\(size)" }

        func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> UIImage? {
            switch item {
            case .data:
                return DownsamplingImageProcessor(size: size).process(item: item, options: options)
            case .image(let image):
                return TimelineImageMemory.displayReadyFrame(image, pixels: size)
            }
        }
    }
#endif

/// Kingfisher's default processor only attaches an animation source for GIF;
/// WebP otherwise becomes a platform image with no playable frame source. ImageIO
/// supplies lazy frames and timing for both formats without decoding an animation
/// into an array. The serializer also preserves WebP bytes instead of making PNG.
nonisolated struct TimelineAnimatedImageProcessor: ImageProcessor, CacheSerializer {
    let identifier = "app.chahua.timeline.imageio-animation"

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo)
        -> KFCrossPlatformImage?
    {
        switch item {
        case .data(let data):
            guard let source = TimelineImageFrameSource(data: data) else { return nil }
            if source.frameCount <= 1 {
                return source.frame(at: 0).map(TimelineImageMemory.image)
            }
            // On AppKit Kingfisher otherwise eagerly decodes every frame, even
            // with preloadAll=false. onlyFirstFrame retains the lazy source there.
            #if os(macOS)
                let creation = ImageCreatingOptions(scale: 1, onlyFirstFrame: true)
            #else
                let creation = ImageCreatingOptions(scale: 1)
            #endif
            return KingfisherWrapper<KFCrossPlatformImage>.animatedImage(
                source: source, options: creation)
        case .image(let image):
            if image.kf.frameSource is TimelineImageFrameSource { return image }
            if let data = image.kf.frameSource?.data ?? image.kf.gifRepresentation() {
                return process(item: .data(data), options: options)
            }
            return TimelineImageMemory.cgImage(image).map(TimelineImageMemory.image)
        }
    }

    func data(with image: KFCrossPlatformImage, original: Data?) -> Data? {
        original ?? image.kf.frameSource?.data
            ?? DefaultCacheSerializer.default.data(with: image, original: nil)
    }

    func image(with data: Data, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        process(item: .data(data), options: options)
    }
}

nonisolated private struct TimelineImageFrameSource: ImageFrameSource {
    let data: Data?
    private let source: CGImageSource

    init?(data: Data) {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary), CGImageSourceGetCount(source) > 0
        else { return nil }
        self.data = data
        self.source = source
    }

    var frameCount: Int { CGImageSourceGetCount(source) }

    func frame(at index: Int, maxSize: CGSize?) -> CGImage? {
        guard index >= 0, index < frameCount else { return nil }
        if let maxSize, maxSize.width > 0, maxSize.height > 0 {
            return CGImageSourceCreateThumbnailAtIndex(
                source, index,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(maxSize.width, maxSize.height),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(
            source, index,
            [
                kCGImageSourceShouldCache: false
            ] as CFDictionary)
    }

    func duration(at index: Int) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any]
        else {
            return 0.1
        }
        let metadata: [CFString: Any]?
        let unclamped: CFString
        let clamped: CFString
        if let webP = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            metadata = webP
            unclamped = kCGImagePropertyWebPUnclampedDelayTime
            clamped = kCGImagePropertyWebPDelayTime
        } else {
            metadata = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            unclamped = kCGImagePropertyGIFUnclampedDelayTime
            clamped = kCGImagePropertyGIFDelayTime
        }
        let delay =
            (metadata?[unclamped] as? NSNumber ?? metadata?[clamped] as? NSNumber)?.doubleValue
            ?? 0.1
        return delay > 0.011 ? delay : 0.1
    }

    func copy() -> Self {
        data.flatMap(Self.init(data:)) ?? self
    }
}

private struct MediaContextKey: EnvironmentKey {
    nonisolated static let defaultValue: AppMediaContext? = nil
}

extension EnvironmentValues {
    var mediaContext: AppMediaContext? {
        get { self[MediaContextKey.self] }
        set { self[MediaContextKey.self] = newValue }
    }
}
