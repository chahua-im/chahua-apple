import Combine
import Foundation
import Kingfisher

/// The asynchronous operation currently affecting the account's image and full-video caches.
enum MediaCacheSettingsState: Equatable {
    case idle
    case refreshing
    case clearing
    case cleared
    case failed
}

@MainActor
final class MediaCacheSettingsModel: ObservableObject {
    @Published private(set) var diskStorageSize: UInt = 0
    @Published private(set) var state: MediaCacheSettingsState = .idle
    @Published private(set) var errorDescription: String?

    private var mediaContext: AppMediaContext?
    private var operationID = 0

    init(mediaContext: AppMediaContext? = nil) {
        self.mediaContext = mediaContext
    }

    /// Switches this model to the supplied account's cache.
    func update(mediaContext: AppMediaContext?) {
        guard
            self.mediaContext.map(ObjectIdentifier.init) != mediaContext.map(ObjectIdentifier.init)
        else { return }
        operationID &+= 1
        self.mediaContext = mediaContext
        diskStorageSize = 0
        errorDescription = nil
        state = .idle
    }

    var isRefreshing: Bool { state == .refreshing }
    var isClearing: Bool { state == .clearing }
    var isBusy: Bool { isRefreshing || isClearing }

    /// Reads the account-scoped image and completed full-video disk cache size in bytes.
    func refresh() async {
        guard !isBusy, let mediaContext else { return }
        let id = beginOperation(state: .refreshing)

        do {
            let imageSize = try await mediaContext.cache.diskStorageSize
            let videoSize = try await mediaContext.videoCache.diskStorageSize()
            let size = imageSize + videoSize
            guard id == operationID else { return }
            diskStorageSize = size
            state = .idle
        } catch {
            finishFailure(for: id, error: error)
        }
    }

    /// Removes the account's image and full-video caches. Playing videos remain pinned until
    /// their players release them; drafts, outgoing messages and other local data are untouched.
    func clear() async {
        guard !isClearing, let mediaContext else { return }
        let id = beginOperation(state: .clearing)
        mediaContext.clearMemoryCache()
        await mediaContext.cache.clearDiskCache()

        do {
            try await mediaContext.videoCache.clear()
            let imageSize = try await mediaContext.cache.diskStorageSize
            let videoSize = try await mediaContext.videoCache.diskStorageSize()
            let size = imageSize + videoSize
            guard id == operationID else { return }
            diskStorageSize = size
            state = .cleared
        } catch {
            finishFailure(for: id, error: error)
        }
    }

    private func beginOperation(state: MediaCacheSettingsState) -> Int {
        operationID &+= 1
        errorDescription = nil
        self.state = state
        return operationID
    }

    private func finishFailure(for id: Int, error: Error) {
        guard id == operationID else { return }
        errorDescription = error.localizedDescription
        state = .failed
    }
}
