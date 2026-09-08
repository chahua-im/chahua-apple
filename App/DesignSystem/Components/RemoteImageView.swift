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
#if os(macOS)
    @State private var nativePhase: NativeRemoteImagePhase = .empty
#endif

    init(
        url: URL?,
        phaseOverride: RemoteImagePhase? = nil,
        contentMode: ContentMode = .fill,
        animates: Bool = false,
        showsBlurredBackdrop: Bool = false
    ) {
        self.url = url
        self.phaseOverride = phaseOverride
        self.contentMode = contentMode
        self.animates = animates
        self.showsBlurredBackdrop = showsBlurredBackdrop
    }

    var body: some View {
        if let phaseOverride {
            content(phaseOverride)
        } else {
#if os(macOS)
            if animates {
                animatedContent
                    .task(id: url) { await loadNativeImage() }
            } else {
                staticContent
            }
#else
            staticContent
#endif
        }
    }

    @ViewBuilder private var staticContent: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty: content(.empty)
                case .success(let image): content(.success(image))
                case .failure: content(.failure)
                @unknown default: content(.failure)
                }
            }
        } else { content(.failure) }
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
    @ViewBuilder private var animatedContent: some View {
        switch nativePhase {
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

    private func loadNativeImage() async {
        nativePhase = .empty
        guard let url else {
            nativePhase = .failure
            return
        }
        do {
            let data: Data
            if url.isFileURL {
                let readTask = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try Data(contentsOf: url)
                }
                data = try await withTaskCancellationHandler {
                    try await readTask.value
                } onCancel: {
                    readTask.cancel()
                }
            } else {
                let (responseData, response) = try await URLSession.shared.data(from: url)
                if let response = response as? HTTPURLResponse, !(200 ..< 300).contains(response.statusCode) {
                    throw URLError(.badServerResponse)
                }
                data = responseData
            }
            try Task.checkCancellation()
            guard let image = NSImage(data: data), image.isValid,
                  image.size.width > 0, image.size.height > 0 else {
                nativePhase = .failure
                return
            }
            nativePhase = .success(image)
        } catch {
            guard !Task.isCancelled else { return }
            nativePhase = .failure
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
