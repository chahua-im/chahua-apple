import ChahuaMediaCache
import Combine
import CryptoKit
import Foundation
import Nuke
import SwiftUI
import os

@MainActor
final class AppMediaContext: ObservableObject {
    @Published private(set) var activationID = UUID()
    @Published private(set) var isReady = false
    @Published private(set) var error: (any Error)?

    private let rootDirectory: URL?
    private let namespace: String
    private let makeCache: @MainActor (CacheConfiguration) async throws -> MediaCache
    private var uid: Int32?
    private var activeResources: (cache: MediaCache, images: MediaImageLoader)?
    private var transition: Task<Void, Never>?
    nonisolated private static let logger = Logger(subsystem: "app.chahua.chat", category: "media-context")

    convenience init(rootDirectory: URL?, namespace: String) {
        self.init(rootDirectory: rootDirectory, namespace: namespace) { configuration in
            try await MediaCache(configuration: configuration)
        }
    }

    init(
        rootDirectory: URL?,
        namespace: String,
        makeCache: @escaping @MainActor (CacheConfiguration) async throws -> MediaCache
    ) {
        self.rootDirectory = rootDirectory
        self.namespace = namespace
        self.makeCache = makeCache
    }

    func activate(uid: Int32?) {
        guard self.uid != uid else { return }
        let previousActivation = AvatarCacheTrace.enabled ? activationID : nil
        let traceStarted: ContinuousClock.Instant? = AvatarCacheTrace.enabled ? .now : nil
        self.uid = uid
        let activation = UUID()
        activationID = activation
        isReady = false
        error = nil
        if let previousActivation {
            AvatarCacheTrace.event("context_activation_start activation=\(activation.uuidString) previous_activation=\(previousActivation.uuidString) ready=false")
        }

        let oldResources = activeResources
        activeResources = nil
        oldResources?.images.close()
        let previous = transition
        let makeCache = makeCache
        let directory = uid.flatMap { uid in
            rootDirectory?.appendingPathComponent(Self.partition(namespace: namespace, uid: uid), isDirectory: true)
        }

        // A stale initializer finishes and closes its own store before its successor starts.
        transition = Task { @MainActor [weak self] in
            var outcome = "superseded"
            defer {
                if let traceStarted {
                    AvatarCacheTrace.event("context_activation_end activation=\(activation.uuidString) outcome=\(outcome) ms=\(AvatarCacheTrace.milliseconds(since: traceStarted))")
                }
            }
            let waitStarted: ContinuousClock.Instant? = traceStarted == nil ? nil : .now
            if traceStarted != nil {
                AvatarCacheTrace.event("context_transition_wait_start activation=\(activation.uuidString)")
            }
            await previous?.value
            if let waitStarted {
                AvatarCacheTrace.event("context_transition_wait_end activation=\(activation.uuidString) ms=\(AvatarCacheTrace.milliseconds(since: waitStarted))")
            }
            do {
                try await oldResources?.cache.shutdown(removingFiles: true)
                guard self?.activationID == activation else { return }
                guard uid != nil else {
                    outcome = "inactive"
                    return
                }
                guard let directory else { throw MediaCacheError.invalidConfiguration }
                let cache = try await makeCache(CacheConfiguration(directory: directory))
                guard let self, self.activationID == activation else {
                    try await cache.shutdown(removingFiles: true)
                    return
                }
                self.activeResources = (cache, MediaImageLoader(cache: cache))
                self.isReady = true
                outcome = "ready"
                AvatarCacheTrace.event("context_resources_ready activation=\(activation.uuidString)")
            } catch {
                if traceStarted != nil {
                    outcome = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled ? "cancelled" : "error"
                }
                guard let self, self.activationID == activation else { return }
                if outcome != "cancelled" {
                    Self.logger.debug("activation-failed activation=\(activation, privacy: .public) domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
                }
                self.error = error
            }
        }
    }

    func cachedImage(for request: MediaRequest, thumbnailPixelSize: CGSize? = nil) -> ImageResponse? {
        guard isReady else {
            if AvatarCacheTrace.enabled, AvatarCacheTrace.load != nil, let key = AvatarCacheTrace.key(for: request) {
                AvatarCacheTrace.event("context_sync_unavailable key=\(key) activation=\(activationID.uuidString) reason=not-ready")
            }
            return nil
        }
        return activeResources?.images.cachedImage(for: request, thumbnailPixelSize: thumbnailPixelSize)
    }

    func resources(for activationID: UUID) async throws -> (cache: MediaCache, images: MediaImageLoader) {
        try Task.checkCancellation()
        guard self.activationID == activationID else { throw MediaCacheError.invalidated }
        await transition?.value
        try Task.checkCancellation()
        guard self.activationID == activationID else { throw MediaCacheError.invalidated }
        if let error { throw error }
        guard let activeResources, isReady else { throw MediaCacheError.closed }
        return activeResources
    }

    private static func partition(namespace: String, uid: Int32) -> String {
        var encoded = Data()
        for component in [namespace, String(uid)] {
            let bytes = Data(component.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
            encoded.append(bytes)
        }
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    deinit {
        let previous = transition
        let resources = activeResources
        Task { @MainActor in
            resources?.images.close()
            await previous?.value
            try? await resources?.cache.shutdown(removingFiles: true)
        }
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
