import CryptoKit
import Foundation
import Kingfisher
import SwiftUI

@MainActor
final class AppMediaContext {
    let cache: ImageCache
    let downloader: ImageDownloader

    convenience init(namespace: String) {
        self.init(
            cache: ImageCache(name: Self.cacheName(namespace: namespace)),
            downloader: .default
        )
    }

    init(cache: ImageCache, downloader: ImageDownloader) {
        self.cache = cache
        self.downloader = downloader
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

private struct MediaContextKey: EnvironmentKey {
    nonisolated static let defaultValue: AppMediaContext? = nil
}

extension EnvironmentValues {
    var mediaContext: AppMediaContext? {
        get { self[MediaContextKey.self] }
        set { self[MediaContextKey.self] = newValue }
    }
}
