import Combine
import Foundation
import Kingfisher

/// Full-resolution detail decoding shares the account cache, not a second URL cache.
@MainActor
final class ImageDetailImageLoader: ObservableObject {
    enum Failure: Equatable {
        case notDownloaded, failed
    }

    @Published private(set) var image: KFCrossPlatformImage?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: Failure?
    private var task: DownloadTask?
    private var generation: UInt64 = 0
    private var item: MessageImageItem?
    private var contextID: ObjectIdentifier?
    private var policyObservation: AnyCancellable?
    private var allowsNetwork = false

    func load(
        _ item: MessageImageItem, mediaContext: AppMediaContext?, userInitiated: Bool = false
    ) {
        let contextID = mediaContext.map(ObjectIdentifier.init)
        if self.item == item, self.contextID == contextID, image != nil || isLoading { return }
        cancel()
        self.item = item
        self.contextID = contextID
        let policy = mediaContext?.loadPolicy ?? .cacheOnly
        let allowsNetwork = policy.allowsNetwork(userInitiated: userInitiated)
        policyObservation = mediaContext?.loadPolicyChanges.sink {
            [weak self, weak mediaContext] policy in
            guard let self, self.image == nil, item.url?.isFileURL == false else { return }
            let allowsNetwork = policy.allowsNetwork(userInitiated: userInitiated)
            guard allowsNetwork != self.allowsNetwork else { return }
            self.start(item, context: mediaContext, allowsNetwork: allowsNetwork)
        }
        start(item, context: mediaContext, allowsNetwork: allowsNetwork)
    }

    private func start(_ item: MessageImageItem, context: AppMediaContext?, allowsNetwork: Bool) {
        cancelRequest()
        self.allowsNetwork = allowsNetwork
        image = nil
        failure = nil
        guard let url = item.url,
            url.isFileURL || ((url.scheme == "https" || url.scheme == "http") && url.host != nil)
        else {
            failure = .failed
            return
        }
        guard url.isFileURL || context != nil else {
            failure = .notDownloaded
            return
        }
        isLoading = true
        let current = generation
        let source: Source =
            url.isFileURL
            ? .provider(LocalFileImageDataProvider(fileURL: url))
            : .network(KF.ImageResource(downloadURL: url))
        var options: KingfisherOptionsInfo = [.cacheOriginalImage, .backgroundDecode, .scaleFactor(1)]
        if let context {
            options += [.targetCache(context.cache), .downloader(context.downloader)]
        }
        if url.isFileURL {
            if context == nil { options += [.forceRefresh, .cacheMemoryOnly] }
        } else if !allowsNetwork {
            options.append(.onlyFromCache)
        }
        task = KingfisherManager.shared.retrieveImage(
            with: source,
            options: options,
            downloadTaskUpdated: { [weak self] task in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current, self.isLoading else {
                        task?.cancel()
                        return
                    }
                    self.task = task
                }
            }
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.task = nil
                self.isLoading = false
                switch result {
                case .success(let value): self.image = value.image
                case .failure:
                    self.failure = allowsNetwork || url.isFileURL ? .failed : .notDownloaded
                }
            }
        }
    }

    /// Cancels work without discarding an already decoded page.
    func cancel() {
        policyObservation = nil
        cancelRequest()
    }

    private func cancelRequest() {
        generation &+= 1
        task?.cancel()
        task = nil
        isLoading = false
    }

    deinit { task?.cancel() }
}
