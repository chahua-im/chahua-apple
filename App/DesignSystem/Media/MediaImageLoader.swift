import ChahuaMediaCache
import Foundation
import Nuke
import os

@MainActor
final class MediaImageLoader {
    private let cache: MediaCache
    private let pipeline: ImagePipeline
    private let imageCache: ImageCache
    private var isClosed = false
    private let logger = Logger(subsystem: "app.chahua.chat", category: "media-images")

    init(cache: MediaCache) {
        self.cache = cache
        let imageCache = ImageCache(costLimit: 67_108_864)
        self.imageCache = imageCache

        let session = URLSessionConfiguration.ephemeral
        session.urlCache = nil
        session.httpCookieStorage = nil
        session.httpShouldSetCookies = false
        session.urlCredentialStorage = nil
        session.requestCachePolicy = .reloadIgnoringLocalCacheData
        var configuration = ImagePipeline.Configuration(dataLoader: DataLoader(configuration: session))
        configuration.imageCache = imageCache
        configuration.dataCache = nil
        configuration.isResumableDataEnabled = false
        pipeline = ImagePipeline(configuration: configuration)
    }

    /// A memory-only first frame; normal acquisition still validates the file and registers tags.
    func cachedImage(for request: MediaRequest, thumbnailPixelSize: CGSize? = nil) -> ImageResponse? {
        guard !isClosed, let identifier = cache.cachedContentIdentifier(for: request) else { return nil }
        var imageRequest = makeImageRequest(url: nil, thumbnailPixelSize: thumbnailPixelSize)
        imageRequest.imageID = identifier
        guard let container = pipeline.cache.cachedImage(for: imageRequest, caches: [.memory]) else { return nil }
        return ImageResponse(container: container, request: imageRequest, cacheType: .memory)
    }

    func image(for request: MediaRequest, thumbnailPixelSize: CGSize? = nil) async throws -> ImageResponse {
        try Task.checkCancellation()
        guard !isClosed else { throw MediaCacheError.closed }
        let loadID = UUID()

        // Even decoded-memory hits must register tags and acquire the current generation.
        let file: CachedFile
        do {
            file = try await cache.file(for: request)
        } catch let error as CancellationError {
            throw error
        } catch {
            logger.debug("file-failed load=\(loadID, privacy: .public) cacheError=\(String(describing: error as? MediaCacheError), privacy: .public) domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            throw error
        }
        do {
            try Task.checkCancellation()
            guard !isClosed else { throw MediaCacheError.closed }
            let imageRequest = makeImageRequest(url: file.url, thumbnailPixelSize: thumbnailPixelSize)
            let response = try await pipeline.imageTask(with: imageRequest).response
            try Task.checkCancellation()
            guard !isClosed else { throw MediaCacheError.closed }
            try await file.checkValidity()
            await file.release()
            try Task.checkCancellation()
            guard !isClosed else { throw MediaCacheError.closed }
            return response
        } catch {
            await file.release()
            try Task.checkCancellation()
            guard !isClosed else { throw MediaCacheError.closed }
            throw error
        }
    }

    private func makeImageRequest(url: URL?, thumbnailPixelSize: CGSize?) -> ImageRequest {
        var request = ImageRequest(url: url, options: [.disableDiskCache])
        if let thumbnailPixelSize {
            request.thumbnail = ImageRequest.ThumbnailOptions(
                size: thumbnailPixelSize,
                unit: .pixels,
                contentMode: .aspectFill
            )
        }
        return request
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pipeline.invalidate()
        imageCache.removeAll()
    }
}
