import ChahuaMediaCache
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum RemoteImagePhase {
    case empty
    case success(Image)
    case failure
}

struct RemoteImageView: View {
    let url: URL?
    let phaseOverride: RemoteImagePhase?
    let contentMode: ContentMode
    let animates: Bool
    let showsBlurredBackdrop: Bool
    let tag: CacheTag
    @Environment(\.mediaContext) private var mediaContext

    init(
        url: URL?,
        phaseOverride: RemoteImagePhase? = nil,
        contentMode: ContentMode = .fill,
        animates: Bool = false,
        showsBlurredBackdrop: Bool = false,
        tag: CacheTag = CacheTag(rawValue: "chatMedia")
    ) {
        self.url = url
        self.phaseOverride = phaseOverride
        self.contentMode = contentMode
        self.animates = animates
        self.showsBlurredBackdrop = showsBlurredBackdrop
        self.tag = tag
    }

    var body: some View {
        if let phaseOverride {
            content(phaseOverride)
        } else {
#if os(macOS)
            if animates {
                animatedContent
            } else {
                staticContent
            }
#else
            staticContent
#endif
        }
    }

    private var staticContent: some View {
        CachedImageView(url: url, tag: tag, content: content)
    }

    @ViewBuilder private func content(_ phase: RemoteImagePhase) -> some View {
        switch phase {
        case .empty: ProgressView()
        case .success(let image):
            if showsBlurredBackdrop {
#if os(macOS)
                imageContent(backdrop: image) {
                    image.resizable().aspectRatio(contentMode: contentMode)
                }
#else
                ZStack {
                    image.resizable().aspectRatio(contentMode: .fill).blur(radius: 20).scaleEffect(1.1).opacity(0.8)
                    Color.black.opacity(0.2)
                    image.resizable().aspectRatio(contentMode: contentMode)
                }
#endif
            } else {
                image.resizable().aspectRatio(contentMode: contentMode)
            }
        case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }

#if os(macOS)
    @ViewBuilder private func nativeContent(_ phase: NativeRemoteImagePhase) -> some View {
        switch phase {
        case .empty:
            content(.empty)
        case .failure:
            content(.failure)
        case .success(let image):
            imageContent(backdrop: Image(nsImage: image)) {
                NativeRemoteImageSurface(image: image, contentMode: contentMode)
            }
        }
    }

    @ViewBuilder private func imageContent<Foreground: View>(backdrop: Image, @ViewBuilder foreground: () -> Foreground) -> some View {
        if showsBlurredBackdrop {
            foreground()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    GeometryReader { geometry in
                        ZStack {
                            Color.black
                            backdrop.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width + 40, height: geometry.size.height + 40)
                                .blur(radius: 20)
                                .opacity(0.8)
                            Color.black.opacity(0.2)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .clipped()
        } else {
            foreground()
        }
    }

    @ViewBuilder private var animatedContent: some View {
        if let url {
            if url.isFileURL {
                NativeImageLoadingView(
                    url: url,
                    tag: tag,
                    context: nil,
                    activationID: nil,
                    content: nativeContent
                )
            } else if let mediaContext {
                ObservedNativeImageView(context: mediaContext, url: url, tag: tag, content: nativeContent)
            } else {
                content(.failure)
            }
        } else {
            content(.failure)
        }
    }
#endif
}

#if os(macOS)
private enum NativeRemoteImagePhase {
    case empty
    case success(NSImage)
    case failure
}

private struct ObservedNativeImageView<Content: View>: View {
    @ObservedObject var context: AppMediaContext
    let url: URL
    let tag: CacheTag
    @ViewBuilder var content: (NativeRemoteImagePhase) -> Content

    var body: some View {
        NativeImageLoadingView(
            url: url,
            tag: tag,
            context: context,
            activationID: context.activationID,
            content: content
        )
    }
}

private struct NativeImageLoadingView<Content: View>: View {
    let url: URL
    let tag: CacheTag
    let context: AppMediaContext?
    let activationID: UUID?
    @ViewBuilder var content: (NativeRemoteImagePhase) -> Content
    @State private var phase: NativeRemoteImagePhase = .empty
    @State private var loadedID: MediaImageTaskID?

    var body: some View {
        let identity = MediaImageTaskID(url: url, tag: tag, activationID: activationID, animates: true)
        content(loadedID == identity ? phase : .empty)
            .task(id: identity) { await loadNativeImage(identity: identity) }
    }

    private func loadNativeImage(identity: MediaImageTaskID) async {
        guard !Task.isCancelled else { return }
        loadedID = identity
        phase = .empty
        var lease: CachedFile?
        do {
            let fileURL: URL
            if url.isFileURL {
                fileURL = url
            } else {
                guard let context, let activationID else { throw MediaCacheError.invalidRequest }
                let resources = try await context.resources(for: activationID)
                try Task.checkCancellation()
                let file = try await resources.cache.file(
                    for: MediaRequest(request: URLRequest(url: url), tags: [tag])
                )
                lease = file
                fileURL = file.url
            }
            let readTask = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try Data(contentsOf: fileURL)
            }
            let data = try await withTaskCancellationHandler {
                try await readTask.value
            } onCancel: {
                readTask.cancel()
            }
            try Task.checkCancellation()
            guard let image = NSImage(data: data), image.isValid,
                  image.size.width > 0, image.size.height > 0 else {
                throw URLError(.cannotDecodeContentData)
            }
            if let lease { try await lease.checkValidity() }
            try Task.checkCancellation()
            if isCurrent(identity) {
                phase = .success(image)
            }
        } catch {
            if !Task.isCancelled, isCurrent(identity) {
                phase = .failure
            }
        }
        if let lease { await lease.release() }
    }

    private func isCurrent(_ identity: MediaImageTaskID) -> Bool {
        loadedID == identity && context?.activationID == identity.activationID
    }
}

private struct NativeRemoteImageSurface: NSViewRepresentable {
    let image: NSImage
    let contentMode: ContentMode

    func makeNSView(context: Context) -> NativeRemoteImageContainer {
        NativeRemoteImageContainer()
    }

    func updateNSView(_ nsView: NativeRemoteImageContainer, context: Context) {
        nsView.update(image: image, contentMode: contentMode)
    }

    static func dismantleNSView(_ nsView: NativeRemoteImageContainer, coordinator: ()) {
        nsView.stop()
    }
}

private final class NativeRemoteImageContainer: NSView {
    private let imageView = NSImageView()
    private var contentMode: ContentMode = .fill

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        .init(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func update(image: NSImage, contentMode: ContentMode) {
        self.contentMode = contentMode
        if imageView.image !== image {
            imageView.animates = false
            imageView.image = image
            imageView.animates = window != nil
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard contentMode == .fill, let size = imageView.image?.size,
              size.width > 0, size.height > 0 else {
            imageView.frame = bounds
            return
        }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        imageView.frame = .init(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        imageView.animates = window != nil
    }

    func stop() {
        imageView.animates = false
        imageView.image = nil
    }
}
#endif
