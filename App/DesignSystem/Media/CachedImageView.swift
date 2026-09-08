import ChahuaMediaCache
import Nuke
import SwiftUI
import os

struct CachedImageView<Content: View>: View {
    let url: URL?
    let tag: CacheTag
    var thumbnailPixelSize: CGSize? = nil
    @ViewBuilder var content: (RemoteImagePhase) -> Content
    @Environment(\.mediaContext) private var mediaContext

    var body: some View {
        if let url {
            if url.isFileURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: content(.empty)
                    case .success(let image): content(.success(image))
                    case .failure: content(.failure)
                    @unknown default: content(.failure)
                    }
                }
            } else if let mediaContext {
                ObservedCachedImageView(
                    context: mediaContext,
                    url: url,
                    tag: tag,
                    thumbnailPixelSize: thumbnailPixelSize,
                    content: content
                )
            } else {
                content(.failure)
                    .onAppear {
                        Logger(subsystem: "app.chahua.chat", category: "media-images")
                            .debug("view-unavailable reason=no-media-context tag=\(tag.rawValue, privacy: .public)")
                    }
            }
        } else {
            content(.failure)
        }
    }
}

struct MediaImageTaskID: Hashable {
    let url: URL
    let tag: CacheTag
    let activationID: UUID?
    let animates: Bool
    let thumbnailWidth: CGFloat?
    let thumbnailHeight: CGFloat?

    init(url: URL, tag: CacheTag, activationID: UUID?, animates: Bool, thumbnailPixelSize: CGSize? = nil) {
        self.url = url
        self.tag = tag
        self.activationID = activationID
        self.animates = animates
        thumbnailWidth = thumbnailPixelSize?.width
        thumbnailHeight = thumbnailPixelSize?.height
    }
}

private struct ObservedCachedImageView<Content: View>: View {
    @ObservedObject var context: AppMediaContext
    let url: URL
    let tag: CacheTag
    let thumbnailPixelSize: CGSize?
    @ViewBuilder var content: (RemoteImagePhase) -> Content
    @State private var phase: RemoteImagePhase = .empty
    @State private var loadedID: MediaImageTaskID?

    private var taskID: MediaImageTaskID {
        MediaImageTaskID(
            url: url,
            tag: tag,
            activationID: context.activationID,
            animates: false,
            thumbnailPixelSize: thumbnailPixelSize
        )
    }

    var body: some View {
        let identity = taskID
        content(loadedID == identity ? phase : cachedPhase ?? .empty)
            .task(id: identity) { await load(identity: identity) }
    }

    private var cachedPhase: RemoteImagePhase? {
        guard let response = context.cachedImage(
            for: MediaRequest(request: URLRequest(url: url), tags: [tag]),
            thumbnailPixelSize: thumbnailPixelSize
        ) else { return nil }
        return imagePhase(response)
    }

    private func imagePhase(_ response: ImageResponse) -> RemoteImagePhase {
#if os(macOS)
        .success(Image(nsImage: response.image))
#else
        .success(Image(uiImage: response.image))
#endif
    }

    private func load(identity: MediaImageTaskID) async {
        guard !Task.isCancelled, let activationID = identity.activationID else { return }
        let firstPhase: RemoteImagePhase
        if loadedID == identity, case .success = phase {
            firstPhase = phase
        } else {
            firstPhase = cachedPhase ?? .empty
        }
        loadedID = identity
        phase = firstPhase
        let showsPlaceholder: Bool
        if case .success = firstPhase {
            showsPlaceholder = false
        } else {
            showsPlaceholder = true
        }
        Logger(subsystem: "app.chahua.chat", category: "media-images")
            .debug("view-loading activation=\(activationID, privacy: .public) tag=\(tag.rawValue, privacy: .public) placeholder=\(showsPlaceholder)")
        do {
            let resources = try await context.resources(for: activationID)
            try Task.checkCancellation()
            let response = try await resources.images.image(
                for: MediaRequest(request: URLRequest(url: url), tags: [tag]),
                thumbnailPixelSize: thumbnailPixelSize
            )
            try Task.checkCancellation()
            guard context.activationID == activationID, loadedID == identity else { return }
            phase = imagePhase(response)
            Logger(subsystem: "app.chahua.chat", category: "media-images")
                .debug("view-ready activation=\(activationID, privacy: .public) tag=\(tag.rawValue, privacy: .public)")
        } catch {
            Logger(subsystem: "app.chahua.chat", category: "media-images")
                .debug("view-failed activation=\(activationID, privacy: .public) tag=\(tag.rawValue, privacy: .public) cancelled=\(Task.isCancelled) domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            guard !Task.isCancelled, context.activationID == activationID, loadedID == identity else { return }
            phase = .failure
        }
    }
}
