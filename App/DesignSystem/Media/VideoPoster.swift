import AVFoundation
import CoreGraphics
import Kingfisher

/// A bounded, cached first frame shared by album tiles and native message bubbles.
/// This extracts a poster; it does not cache the full video.
nonisolated final class VideoPoster: ImageDataProvider, @unchecked Sendable {
    static let pixelSize = CGSize(width: 512, height: 512)
    private let provider: AVAssetImageDataProvider
    private let lock = NSLock()
    private var cancelled = false

    var cacheKey: String { provider.cacheKey }

    @MainActor
    init(url: URL) {
        provider = AVAssetImageDataProvider(assetURL: url, seconds: 0)
        provider.assetImageGenerator.maximumSize = Self.pixelSize
    }

    func data(handler: @escaping @Sendable (Result<Data, any Error>) -> Void) {
        // A disk lookup may reach the provider after its view disappeared.
        // Fence that late start as well as cancelling already-enqueued AV work.
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            handler(.failure(AVAssetImageDataProvider.AVAssetImageDataProviderError.userCancelled))
            return
        }
        provider.data(handler: handler)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        provider.assetImageGenerator.cancelAllCGImageGeneration()
    }
}
