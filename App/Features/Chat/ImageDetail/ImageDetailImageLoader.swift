import Combine
import Foundation
import Kingfisher

/// Full-resolution detail decoding shares the account cache, not a second URL cache.
@MainActor
final class ImageDetailImageLoader: ObservableObject {
    @Published private(set) var image: KFCrossPlatformImage?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    private var task: DownloadTask?
    private var generation: UInt64 = 0
    private var item: MessageImageItem?
    private var contextID: ObjectIdentifier?

    func load(_ item: MessageImageItem, mediaContext: AppMediaContext?) {
        let contextID = mediaContext.map(ObjectIdentifier.init)
        if self.item == item, self.contextID == contextID, image != nil || isLoading { return }
        cancel()
        self.item = item
        self.contextID = contextID
        image = nil
        failed = false
        guard let url = item.url,
              url.isFileURL || ((url.scheme == "https" || url.scheme == "http") && url.host != nil) else {
            failed = true
            return
        }
        isLoading = true
        let current = generation
        let source: Source = url.isFileURL
            ? .provider(LocalFileImageDataProvider(fileURL: url)) : .network(KF.ImageResource(downloadURL: url))
        task = KingfisherManager.shared.retrieveImage(with: source, options: [
            .targetCache(mediaContext?.cache ?? .default), .downloader(mediaContext?.downloader ?? .default),
            .cacheOriginalImage, .backgroundDecode, .scaleFactor(1),
        ]) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.task = nil
                self.isLoading = false
                switch result {
                case .success(let value): self.image = value.image
                case .failure: self.failed = true
                }
            }
        }
    }

    /// Cancels work without discarding an already decoded page.
    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isLoading = false
    }

    deinit { task?.cancel() }
}
