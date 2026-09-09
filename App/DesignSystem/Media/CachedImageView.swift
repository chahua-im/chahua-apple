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
    @State private var contentIdentifier: String?
    @State private var invalidationRevision = 0
    @State private var traceViewID: UUID? = AvatarCacheTrace.enabled ? UUID() : nil

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
        let holdsPhase = loadedID == identity
        let renderedPhase = holdsPhase ? phase : cachedPhase ?? .empty
        content(renderedPhase)
            .onAppear {
                guard let trace = traceDetails(for: identity) else { return }
                AvatarCacheTrace.event("view_appear \(trace) phase=\(phaseName(renderedPhase)) decision=\(renderDecision(renderedPhase, held: holdsPhase))")
            }
            .onDisappear {
                if let trace = traceDetails(for: identity) {
                    AvatarCacheTrace.event("view_disappear \(trace) phase=\(phaseName(renderedPhase)) decision=\(renderDecision(renderedPhase, held: holdsPhase))")
                }
                // Detached views do not observe invalidation. Reappearance must go through
                // the cache's eligibility check, not replay a previously held success.
                loadedID = nil
                contentIdentifier = nil
                phase = .empty
            }
            .task(id: identity) {
                guard let trace = traceDetails(for: identity) else {
                    await load(identity: identity)
                    return
                }
                await AvatarCacheTrace.$load.withValue(UUID().uuidString) {
                    let started = ContinuousClock.now
                    AvatarCacheTrace.event("view_task_start \(trace) rendered_phase=\(phaseName(renderedPhase)) decision=\(renderDecision(renderedPhase, held: holdsPhase))")
                    await load(identity: identity, trace: trace)
                    AvatarCacheTrace.event("view_task_end \(trace) outcome=\(Task.isCancelled ? "cancelled" : "finished") ms=\(AvatarCacheTrace.milliseconds(since: started))")
                }
            }
    }

    private var cachedResponse: ImageResponse? {
        context.cachedImage(
            for: MediaRequest(request: URLRequest(url: url), tags: [tag]),
            thumbnailPixelSize: thumbnailPixelSize
        )
    }

    private var cachedPhase: RemoteImagePhase? {
        cachedResponse.map(imagePhase)
    }

    private func imagePhase(_ response: ImageResponse) -> RemoteImagePhase {
#if os(macOS)
        .success(Image(nsImage: response.image))
#else
        .success(Image(uiImage: response.image))
#endif
    }

    private func load(identity: MediaImageTaskID, trace: String? = nil) async {
        guard !Task.isCancelled, let activationID = identity.activationID else {
            if let trace {
                AvatarCacheTrace.event("view_task_skip \(trace) reason=\(Task.isCancelled ? "cancelled" : "no-activation")")
            }
            return
        }
        let response = cachedResponse
        let firstPhase = response.map(imagePhase) ?? .empty
        contentIdentifier = response?.request.url?.absoluteString ?? response?.request.imageID
        loadedID = identity
        phase = firstPhase
        let revision = invalidationRevision
        var observation: Task<Void, Never>?
        defer { observation?.cancel() }
        if let trace {
            AvatarCacheTrace.event("view_initial_assignment \(trace) phase=\(phaseName(firstPhase)) decision=\(renderDecision(firstPhase, held: false))")
        }
        var resourceWaitStarted: ContinuousClock.Instant? = trace == nil ? nil : .now
        if let trace {
            AvatarCacheTrace.event("view_resources_wait_start \(trace)")
        }
        do {
            let resources = try await context.resources(for: activationID)
            if let trace, let started = resourceWaitStarted {
                AvatarCacheTrace.event("view_resources_wait_end \(trace) outcome=ready ms=\(AvatarCacheTrace.milliseconds(since: started))")
            }
            resourceWaitStarted = nil
            try Task.checkCancellation()
            let invalidations = await resources.cache.invalidations()
            try Task.checkCancellation()
            // A removal may have happened while obtaining the resources/subscription.
            // Recheck the first frame after registration so that event gap cannot retain it.
            if contentIdentifier != nil, cachedResponse == nil {
                contentIdentifier = nil
                phase = .empty
            }
            observation = Task { @MainActor in
                for await invalidation in invalidations {
                    guard !Task.isCancelled, context.activationID == activationID, loadedID == identity else { return }
                    switch invalidation {
                    case .all:
                        invalidationRevision += 1
                    case .tags(let tags):
                        guard tags.contains(tag) else { continue }
                        invalidationRevision += 1
                    case .contentIdentifier(let identifier):
                        guard identifier == contentIdentifier else { continue }
                    }
                    contentIdentifier = nil
                    phase = .empty
                }
            }
            let response = try await resources.images.image(
                for: MediaRequest(request: URLRequest(url: url), tags: [tag]),
                thumbnailPixelSize: thumbnailPixelSize,
                onCachedImage: { response in
                    guard !Task.isCancelled, context.activationID == activationID,
                          loadedID == identity, invalidationRevision == revision else { return }
                    contentIdentifier = response.request.url?.absoluteString ?? response.request.imageID
                    phase = imagePhase(response)
                }
            )
            try Task.checkCancellation()
            guard context.activationID == activationID, loadedID == identity,
                  invalidationRevision == revision else {
                if let trace {
                    AvatarCacheTrace.event("view_outdated \(trace) stage=image-result")
                }
                return
            }
            contentIdentifier = response.request.url?.absoluteString ?? response.request.imageID
            phase = imagePhase(response)
            if let trace {
                AvatarCacheTrace.event("view_async_assignment \(trace) phase=success")
            }
        } catch {
            let cancelled = trace != nil && (Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled)
            if let trace {
                if let started = resourceWaitStarted {
                    AvatarCacheTrace.event("view_resources_wait_end \(trace) outcome=\(cancelled ? "cancelled" : "error") ms=\(AvatarCacheTrace.milliseconds(since: started))")
                }
                if cancelled {
                    AvatarCacheTrace.event("view_cancelled \(trace)")
                } else if context.activationID != activationID || loadedID != identity {
                    AvatarCacheTrace.event("view_outdated \(trace) stage=error")
                } else {
                    AvatarCacheTrace.event("view_load_error \(trace)")
                }
            }
            guard !Task.isCancelled, context.activationID == activationID, loadedID == identity else { return }
            if case .success = phase {
                if let trace {
                    AvatarCacheTrace.event("view_async_assignment \(trace) phase=success reason=refresh-failed")
                }
            } else {
                contentIdentifier = nil
                phase = .failure
                if let trace, !cancelled {
                    AvatarCacheTrace.event("view_async_assignment \(trace) phase=failure")
                }
            }
        }
        // Keep revocation observation alive for settled and failed-refresh images too.
        if let observation {
            await withTaskCancellationHandler {
                await observation.value
            } onCancel: {
                observation.cancel()
            }
        }
    }

    private func traceDetails(for identity: MediaImageTaskID) -> String? {
        guard let traceViewID,
              let key = AvatarCacheTrace.key(for: MediaRequest(request: URLRequest(url: identity.url), tags: [identity.tag]))
        else { return nil }
        let thumbnail: String
        if let width = identity.thumbnailWidth, let height = identity.thumbnailHeight {
            thumbnail = "\(width)x\(height)"
        } else {
            thumbnail = "full"
        }
        return "view=\(traceViewID.uuidString) key=\(key) thumbnail=\(thumbnail) activation=\(identity.activationID?.uuidString ?? "none")"
    }

    private func phaseName(_ phase: RemoteImagePhase) -> String {
        switch phase {
        case .empty: "empty"
        case .success: "success"
        case .failure: "failure"
        }
    }

    private func renderDecision(_ phase: RemoteImagePhase, held: Bool) -> String {
        switch phase {
        case .success: held ? "held-image" : "cached-phase"
        case .empty: "placeholder"
        case .failure: "failure"
        }
    }
}
