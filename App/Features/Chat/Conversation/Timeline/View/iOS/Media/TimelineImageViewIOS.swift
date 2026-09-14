#if os(iOS)
import CoreImage
import Kingfisher
import UIKit

/// Native image views avoid a SwiftUI subtree and its independent layout/lifecycle
/// in every measured timeline row. Only pixels change after decoding; UIKit keeps
/// the layout engine's frame and explicitly suspends work for nonvisible cells.
@MainActor
final class TimelineImageView: UIView {
    enum ScalingMode { case fit, fill }

    private struct RequestKey: Equatable {
        let url: URL?
        let pixels: CGSize
        let context: ObjectIdentifier?
        let animates: Bool
    }

    private let foreground = UIImageView(frame: .zero)
    private var animatedForeground: AnimatedImageView?
    private let backdrop = CALayer()
    private let backdropCover = CALayer()
    private let progress = UIActivityIndicatorView(style: .medium)
    private let errorImage = UIImageView(image: UIImage(systemName: "photo"))
    private var requestKey: RequestKey?
    private var mediaContext: AppMediaContext?
    private var scalingMode: ScalingMode = .fit
    private var showsBackdrop = false
    private var requestedVisible = false
    private var active = false
    private var generation: UInt64 = 0
    private var staticLoading = false
    private var animationLoading = false
    private var staticFailed = false
    private var animationFinished = false
    private var isLocal = false
    private var decodedImage: UIImage?
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backdrop.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        backdrop.opacity = 0.8
        backdrop.contentsGravity = .resize
        backdropCover.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        backdropCover.backgroundColor = UIColor.black.withAlphaComponent(0.2).cgColor
        layer.addSublayer(backdrop)
        layer.addSublayer(backdropCover)
        foreground.contentMode = .scaleToFill
        addSubview(foreground)
        progress.hidesWhenStopped = true
        addSubview(progress)
        errorImage.tintColor = .secondaryLabel
        errorImage.contentMode = .scaleAspectFit
        addSubview(errorImage)
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification, UIScene.didActivateNotification,
                     UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
        }
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

    func configure(url: URL?, contentMode: ScalingMode, animates: Bool, showsBlurredBackdrop: Bool,
                   thumbnailPixelSize: CGSize, mediaContext: AppMediaContext?) {
        let pixels = CGSize(width: max(1, thumbnailPixelSize.width), height: max(1, thumbnailPixelSize.height))
        let key = RequestKey(url: url, pixels: pixels, context: mediaContext.map(ObjectIdentifier.init), animates: animates)
        if key != requestKey || isLocal {
            clearPayload()
            requestKey = key
            self.mediaContext = mediaContext
            staticFailed = url == nil
            // Keep CachedImageView's processor and scale key so native rows share
            // the account's existing memory/disk cache, including the first bind.
            if let url, let image = (mediaContext?.cache ?? .default).retrieveImageInMemoryCache(
                forKey: url.absoluteString,
                options: [.processor(DownsamplingImageProcessor(size: pixels)), .scaleFactor(1)]
            ) {
                installStatic(image)
            }
        } else {
            self.mediaContext = mediaContext
        }
        scalingMode = contentMode
        setBackdropEnabled(showsBlurredBackdrop)
        setNeedsLayout()
        refreshVisibility()
        updateChrome()
    }

    func configureLocal(image: CGImage?, contentMode: ScalingMode, showsBlurredBackdrop: Bool, isLoading: Bool) {
        clearPayload()
        isLocal = true
        scalingMode = contentMode
        staticLoading = isLoading
        staticFailed = image == nil && !isLoading
        if let image { installStatic(UIImage(cgImage: image)) }
        setBackdropEnabled(showsBlurredBackdrop)
        setNeedsLayout()
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshVisibility()
    }

    override var isHidden: Bool {
        didSet { refreshVisibility() }
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
             UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification:
            suspend()
        default:
            refreshVisibility()
        }
    }

    private func suspend() {
        active = false
        cancelRequests(preservingImages: true)
        cancelBackdrop()
        updateChrome()
    }

    private func refreshVisibility() {
        let visible = requestedVisible && timelineMediaIsVisible
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
        if active && animatedForeground?.isHidden == false {
            animatedForeground?.startAnimating()
        } else {
            animatedForeground?.stopAnimating()
        }
        updateChrome()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        backdropCover.frame = bounds
        foreground.frame = imageFrame(for: decodedImage?.size ?? .zero)
        if let animatedForeground {
            animatedForeground.frame = imageFrame(for: animatedForeground.image?.size ?? decodedImage?.size ?? .zero)
        }
        progress.center = CGPoint(x: bounds.midX, y: bounds.midY)
        errorImage.frame = CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
        CATransaction.commit()
        refreshVisibility()
    }

    private func imageFrame(for size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let x = bounds.width / size.width
        let y = bounds.height / size.height
        let scale = scalingMode == .fit ? min(x, y) : max(x, y)
        let result = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - result.width / 2, y: bounds.midY - result.height / 2,
                      width: result.width, height: result.height)
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
                self.setNeedsLayout()
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
                    self.animatedForeground?.isHidden = frames <= 1
                    if self.decodedImage == nil { self.installStatic(value.image) }
                    if frames <= 1 { self.animatedForeground?.image = nil }
                case .failure:
                    self.animatedForeground?.image = nil
                    self.animatedForeground?.isHidden = true
                }
                self.setNeedsLayout()
                self.refreshVisibility()
            }
        }
    }

    private func makeAnimatedForeground() -> AnimatedImageView {
        if let animatedForeground { return animatedForeground }
        let view = AnimatedImageView(frame: bounds)
        view.autoPlayAnimatedImage = false
        view.contentMode = .scaleToFill
        // Aspect fitting comes from the outer measured frame, not a previous
        // cell size captured inside the animator's pre-scaled frame buffer.
        view.needsPrescaling = false
        view.isHidden = true
        insertSubview(view, aboveSubview: foreground)
        animatedForeground = view
        return view
    }

    private func installStatic(_ image: UIImage) {
        decodedImage = image
        foreground.image = image
        decodedCGImage = image.cgImage
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
        backgroundColor = enabled ? .black : .clear
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
        if loading && active { progress.startAnimating() } else { progress.stopAnimating() }
    }

    private func cancelRequests(preservingImages: Bool) {
        generation &+= 1
        if staticLoading || !preservingImages {
            let image = preservingImages ? decodedImage : nil
            foreground.kf.cancelDownloadTask()
            // Reset the Kingfisher task identifier too: cancellation alone can
            // still deliver a completion to a reused image view.
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
        let scale = max(1, traitCollection.displayScale)
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
            .transformed(by: CGAffineTransform(translationX: (width - CGFloat(image.width) * factor) / 2,
                                              y: (height - CGFloat(image.height) * factor) / 2))
        let crop = CGRect(x: 0, y: 0, width: width, height: height)
        let blurred = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 20 * scale])
            .cropped(to: crop)
        guard !Task.isCancelled else { return nil }
        return backdropContext.createCGImage(blurred, from: crop)
    }
}

extension UIView {
    /// The row owns viewport visibility; native media also stops for detached,
    /// hidden, or backgrounded windows even before collection reuse runs.
    var timelineMediaIsVisible: Bool {
        guard let window, !bounds.isEmpty else { return false }
        if let scene = window.windowScene {
            guard scene.activationState == .foregroundActive else { return false }
        } else if UIApplication.shared.applicationState != .active {
            return false
        }
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0 else { return false }
            ancestor = view.superview
        }
        return convert(bounds, to: window).intersects(window.bounds)
    }
}
#endif
