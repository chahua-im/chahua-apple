#if os(macOS)
import AppKit
import CoreImage
import Kingfisher

/// Native media avoids the measured per-row NSHostingView/AttributeGraph cost. The
/// timeline owns geometry; decoding only changes pixels, never the assigned frame.
@MainActor
final class TimelineImageView: NSView {
    enum ContentMode { case fit, fill }

    private struct RequestKey: Equatable {
        let url: URL?
        let pixels: CGSize
        let context: ObjectIdentifier?
        let animates: Bool
    }

    private let foreground = NSImageView(frame: .zero)
    private var animatedForeground: AnimatedImageView?
    private let backdrop = CALayer()
    private let backdropCover = CALayer()
    private let progress = NSProgressIndicator(frame: .zero)
    private let errorImage = NSImageView(frame: .zero)
    private var requestKey: RequestKey?
    private var mediaContext: AppMediaContext?
    private var contentMode: ContentMode = .fit
    private var showsBackdrop = false
    private var requestedVisible = false
    private var active = false
    private var generation: UInt64 = 0
    private var staticLoading = false
    private var animationLoading = false
    private var staticFailed = false
    private var animationFinished = false
    private var isLocal = false
    private var decodedImage: NSImage?
    private var decodedCGImage: CGImage?
    private var backdropSize = CGSize.zero
    private var backdropScale: CGFloat = 0
    private var backdropGeneration: UInt64 = 0
    private var backdropWorker: Task<CGImage?, Never>?
    private var backdropCompletion: Task<Void, Never>?
    private var reportedImageAvailability = false
    var onImageAvailabilityChanged: ((Bool) -> Void)?

    var showsPlaceholderChrome = true {
        didSet { updateChrome() }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        backdrop.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        backdrop.opacity = 0.8
        backdrop.contentsGravity = .resize
        backdropCover.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        backdropCover.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        layer?.addSublayer(backdrop)
        layer?.addSublayer(backdropCover)
        foreground.imageScaling = .scaleAxesIndependently
        foreground.animates = false
        addSubview(foreground)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        addSubview(progress)
        errorImage.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        errorImage.contentTintColor = .secondaryLabelColor
        errorImage.imageScaling = .scaleProportionallyUpOrDown
        addSubview(errorImage)
        setAccessibilityElement(false)
        updateChrome()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        backdropWorker?.cancel()
        backdropCompletion?.cancel()
        NotificationCenter.default.removeObserver(self)
        MainActor.assumeIsolated {
            foreground.kf.cancelDownloadTask()
            animatedForeground?.kf.cancelDownloadTask()
            animatedForeground?.stopAnimating()
        }
    }

    func configure(
        url: URL?,
        contentMode: ContentMode,
        animates: Bool,
        showsBlurredBackdrop: Bool,
        thumbnailPixelSize: CGSize,
        mediaContext: AppMediaContext?
    ) {
        let pixels = CGSize(width: max(1, thumbnailPixelSize.width), height: max(1, thumbnailPixelSize.height))
        let key = RequestKey(url: url, pixels: pixels, context: mediaContext.map(ObjectIdentifier.init), animates: animates)
        if key != requestKey || isLocal {
            clearPayload()
            requestKey = key
            self.mediaContext = mediaContext
            staticFailed = url == nil
            // Match CachedImageView's processor and scale cache key before starting
            // asynchronous work, including when this view has not been attached yet.
            if let url, let image = (mediaContext?.cache ?? .default).retrieveImageInMemoryCache(
                forKey: url.absoluteString,
                options: [.processor(DownsamplingImageProcessor(size: pixels)), .scaleFactor(1)]
            ) {
                installStatic(image)
            }
        } else {
            self.mediaContext = mediaContext
        }
        self.contentMode = contentMode
        setBackdropEnabled(showsBlurredBackdrop)
        needsLayout = true
        refreshVisibility()
        startMissingRequests()
        updateChrome()
    }

    /// The pending tile owns its cancellable ImageIO task; the resulting first
    /// frame uses exactly the same fit/backdrop rendering as a delivered image.
    func configureLocal(image: CGImage?, contentMode: ContentMode, showsBlurredBackdrop: Bool, isLoading: Bool) {
        clearPayload()
        isLocal = true
        self.contentMode = contentMode
        staticLoading = isLoading
        staticFailed = image == nil && !isLoading
        if let image {
            installStatic(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        }
        setBackdropEnabled(showsBlurredBackdrop)
        needsLayout = true
        refreshVisibility()
        updateChrome()
    }

    func setVisible(_ visible: Bool) {
        requestedVisible = visible
        refreshVisibility()
    }

    func clear() {
        requestedVisible = false
        active = false
        clearPayload()
        setBackdropEnabled(false)
        updateChrome()
        onImageAvailabilityChanged = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged), name: name, object: window)
            }
        }
        refreshVisibility()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshVisibility()
    }

    @objc private func windowVisibilityChanged() { refreshVisibility() }

    private func refreshVisibility() {
        let visible = requestedVisible && window != nil && !isHiddenOrHasHiddenAncestor
            && !visibleRect.isEmpty && window?.isVisible == true && window?.isMiniaturized == false
        if active != visible {
            active = visible
            if !visible {
                cancelRequests(preservingImages: true)
                cancelBackdrop()
            }
        }
        if active {
            startMissingRequests()
            prepareBackdropIfNeeded()
        }
        if active && window?.occlusionState.contains(.visible) == true && animatedForeground?.isHidden == false {
            animatedForeground?.startAnimating()
        } else {
            animatedForeground?.stopAnimating()
        }
        updateChrome()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        backdropCover.frame = bounds
        foreground.frame = imageFrame(for: decodedImage?.size ?? .zero)
        if let animatedForeground {
            animatedForeground.frame = imageFrame(for: animatedForeground.image?.size ?? decodedImage?.size ?? .zero)
        }
        progress.frame = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
        errorImage.frame = CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
        CATransaction.commit()
        refreshVisibility()
    }

    private func imageFrame(for size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let x = bounds.width / size.width
        let y = bounds.height / size.height
        let scale = contentMode == .fit ? min(x, y) : max(x, y)
        let result = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - result.width / 2, y: bounds.midY - result.height / 2, width: result.width, height: result.height)
    }

    private func startMissingRequests() {
        guard active, !isLocal, let key = requestKey, let url = key.url else { return }
        let current = generation
        if decodedImage == nil && !staticLoading && !staticFailed {
            staticLoading = true
            let options: KingfisherOptionsInfo = [
                .processor(DownsamplingImageProcessor(size: key.pixels)), .scaleFactor(1),
                .targetCache(mediaContext?.cache ?? .default), .downloader(mediaContext?.downloader ?? .default),
                .cacheOriginalImage,
            ]
            foreground.kf.setImage(with: url, options: options) { [weak self] result in
                guard let self, self.generation == current, self.requestKey == key else { return }
                self.staticLoading = false
                switch result {
                case .success(let value): self.installStatic(value.image)
                case .failure: self.staticFailed = true
                }
                self.needsLayout = true
                self.updateChrome()
            }
        }
        if key.animates && !animationLoading && !animationFinished {
            let animated = makeAnimatedForeground()
            animationLoading = true
            animated.kf.setImage(with: url, options: [
                .targetCache(mediaContext?.cache ?? .default), .downloader(mediaContext?.downloader ?? .default),
                .cacheOriginalImage,
            ]) { [weak self] result in
                guard let self, self.generation == current, self.requestKey == key else { return }
                self.animationLoading = false
                self.animationFinished = true
                switch result {
                case .success(let value):
                    let frames = value.image.kf.frameSource?.frameCount ?? value.image.kf.imageFrameCount ?? 1
                    // A single-frame WebP must use the sharp static foreground,
                    // not AnimatedImageView's animation-only layer renderer.
                    self.animatedForeground?.isHidden = frames <= 1
                    if self.decodedImage == nil { self.installStatic(value.image) }
                    if frames <= 1 { self.animatedForeground?.image = nil }
                case .failure:
                    self.animatedForeground?.image = nil
                    self.animatedForeground?.isHidden = true
                }
                self.needsLayout = true
                self.refreshVisibility()
            }
        }
    }

    private func makeAnimatedForeground() -> AnimatedImageView {
        if let animatedForeground { return animatedForeground }
        let view = AnimatedImageView(frame: bounds)
        view.autoPlayAnimatedImage = false
        view.imageScaling = .scaleAxesIndependently
        // The outer aspect-preserving frame is authoritative at every resize.
        // Avoid pre-scaling frames to a former row size inside the animator.
        view.needsPrescaling = false
        view.isHidden = true
        addSubview(view, positioned: .above, relativeTo: foreground)
        animatedForeground = view
        return view
    }

    private func installStatic(_ image: NSImage) {
        decodedImage = image
        foreground.image = image
        var proposed = CGRect(origin: .zero, size: image.size)
        decodedCGImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        staticFailed = false
        cancelBackdrop()
        backdrop.contents = nil
        backdropSize = .zero
        prepareBackdropIfNeeded()
    }

    private func setBackdropEnabled(_ enabled: Bool) {
        if showsBackdrop != enabled {
            showsBackdrop = enabled
            cancelBackdrop()
            backdrop.contents = nil
            backdropSize = .zero
        }
        backdrop.isHidden = !enabled
        backdropCover.isHidden = !enabled
        layer?.backgroundColor = enabled ? NSColor.black.cgColor : nil
        if enabled { prepareBackdropIfNeeded() }
    }

    private func updateChrome() {
        let hasImage = decodedImage != nil || animatedForeground?.isHidden == false
        if hasImage != reportedImageAvailability {
            reportedImageAvailability = hasImage
            onImageAvailabilityChanged?(hasImage)
        }
        errorImage.isHidden = !showsPlaceholderChrome || !staticFailed || hasImage
        let loading = showsPlaceholderChrome && !hasImage && !staticFailed && (requestKey?.url != nil || staticLoading)
        progress.isHidden = !loading
        if loading && active { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private func cancelRequests(preservingImages: Bool) {
        generation &+= 1
        // Completed images and their animator stay intact in the bounded reuse
        // cell. Only unfinished requests need their Kingfisher identifier reset.
        if staticLoading || !preservingImages {
            let image = preservingImages ? decodedImage : nil
            foreground.kf.cancelDownloadTask()
            // Cancel alone does not invalidate Kingfisher's view task identifier.
            foreground.kf.setImage(with: Optional<URL>.none)
            foreground.image = image
        }
        if animationLoading || !preservingImages {
            animatedForeground?.kf.cancelDownloadTask()
            animatedForeground?.kf.setImage(with: Optional<URL>.none)
        }
        animatedForeground?.stopAnimating()
        staticLoading = isLocal && staticLoading
        animationLoading = false
    }

    private func clearPayload() {
        cancelRequests(preservingImages: false)
        cancelBackdrop()
        requestKey = nil
        mediaContext = nil
        decodedImage = nil
        decodedCGImage = nil
        isLocal = false
        staticLoading = false
        staticFailed = false
        animationFinished = false
        animatedForeground?.isHidden = true
        backdrop.contents = nil
        backdropSize = .zero
    }

    private func cancelBackdrop() {
        let wasPreparing = backdropWorker != nil
        backdropGeneration &+= 1
        backdropWorker?.cancel()
        backdropWorker = nil
        backdropCompletion?.cancel()
        backdropCompletion = nil
        if wasPreparing || backdrop.contents == nil { backdropSize = .zero }
    }

    private func prepareBackdropIfNeeded() {
        guard active, showsBackdrop, let image = decodedCGImage, bounds.width > 0, bounds.height > 0 else { return }
        let size = bounds.size
        let scale = max(1, window?.backingScaleFactor ?? 2)
        guard size != backdropSize || scale != backdropScale else { return }
        cancelBackdrop()
        backdropSize = size
        backdropScale = scale
        let current = backdropGeneration
        let worker = Task.detached(priority: .utility) {
            Self.makeBackdrop(image: image, size: size, scale: scale)
        }
        backdropWorker = worker
        backdropCompletion = Task { [weak self] in
            let blurred = await worker.value
            guard !Task.isCancelled, let self, self.backdropGeneration == current, self.active else { return }
            self.backdropWorker = nil
            self.backdropCompletion = nil
            self.backdrop.contentsScale = scale
            self.backdrop.contents = blurred
        }
    }

    nonisolated private static let backdropContext = CIContext(options: [.cacheIntermediates: false])

    nonisolated private static func makeBackdrop(image: CGImage, size: CGSize, scale: CGFloat) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let width = ceil(size.width * scale)
        let height = ceil(size.height * scale)
        let expansion = 40 * scale
        let factor = max((width + expansion) / CGFloat(image.width), (height + expansion) / CGFloat(image.height))
        let source = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .transformed(by: CGAffineTransform(
                translationX: (width - CGFloat(image.width) * factor) / 2,
                y: (height - CGFloat(image.height) * factor) / 2
            ))
        let crop = CGRect(x: 0, y: 0, width: width, height: height)
        let blurred = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 20 * scale])
            .cropped(to: crop)
        guard !Task.isCancelled else { return nil }
        return backdropContext.createCGImage(blurred, from: crop)
    }
}
#endif
