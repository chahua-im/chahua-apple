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
        private var imageTask: DownloadTask?
        private var loading = false
        private var failed = false
        private var requestFinished = false
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
        var onLoadFailure: ((String) -> Void)?

        var showsPlaceholderChrome = true {
            didSet { updateChrome() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            backdrop.actions = [
                "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
            ]
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
            for name in [
                UIApplication.didBecomeActiveNotification,
                UIApplication.willResignActiveNotification,
                UIApplication.didEnterBackgroundNotification, UIScene.didActivateNotification,
                UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(visibilityChanged), name: name, object: nil)
            }
            updateChrome()
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            backdropWorker?.cancel()
            backdropCompletion?.cancel()
            NotificationCenter.default.removeObserver(self)
            MainActor.assumeIsolated {
                imageTask?.cancel()
                animatedForeground?.stopAnimating()
            }
        }

        func configure(
            url: URL?, contentMode: ScalingMode, animates: Bool, showsBlurredBackdrop: Bool,
            thumbnailPixelSize: CGSize, mediaContext: AppMediaContext?
        ) {
            let pixels = CGSize(
                width: max(1, thumbnailPixelSize.width), height: max(1, thumbnailPixelSize.height))
            let key = RequestKey(
                url: url, pixels: pixels, context: mediaContext.map(ObjectIdentifier.init),
                animates: animates)
            if key != requestKey || isLocal {
                let sameMedia =
                    !isLocal && url != nil && requestKey?.url == url
                    && requestKey?.context == key.context
                if sameMedia {
                    cancelRequests(preservingImages: true)
                    requestFinished = animates && requestKey?.animates == true && requestFinished
                    if !animates {
                        animatedForeground?.image = nil
                        animatedForeground?.isHidden = true
                        foreground.isHidden = false
                    }
                } else {
                    clearPayload()
                }
                requestKey = key
                self.mediaContext = mediaContext
                failed = failed || url == nil
                restoreFromMemory()
            } else {
                self.mediaContext = mediaContext
            }
            scalingMode = contentMode
            setBackdropEnabled(showsBlurredBackdrop)
            setNeedsLayout()
            refreshVisibility()
            updateChrome()
        }

        func configureLocal(
            image: CGImage?, contentMode: ScalingMode, showsBlurredBackdrop: Bool, isLoading: Bool
        ) {
            clearPayload()
            isLocal = true
            scalingMode = contentMode
            loading = isLoading
            failed = image == nil && !isLoading
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
            onLoadFailure = nil
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
            case UIApplication.willResignActiveNotification,
                UIApplication.didEnterBackgroundNotification,
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
                animatedForeground.frame = imageFrame(
                    for: animatedForeground.image?.size ?? decodedImage?.size ?? .zero)
            }
            progress.center = CGPoint(x: bounds.midX, y: bounds.midY)
            errorImage.frame = CGRect(
                x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
            CATransaction.commit()
            refreshVisibility()
        }

        private func imageFrame(for size: CGSize) -> CGRect {
            guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
                return bounds
            }
            let x = bounds.width / size.width
            let y = bounds.height / size.height
            let scale = scalingMode == .fit ? min(x, y) : max(x, y)
            let result = CGSize(width: size.width * scale, height: size.height * scale)
            return CGRect(
                x: bounds.midX - result.width / 2, y: bounds.midY - result.height / 2,
                width: result.width, height: result.height)
        }

        private func imageOptions(for key: RequestKey) -> KingfisherOptionsInfo {
            var options: KingfisherOptionsInfo = [
                .scaleFactor(1), .targetCache(mediaContext?.cache ?? .default),
                .downloader(mediaContext?.downloader ?? .default), .cacheOriginalImage,
                .callbackQueue(.mainCurrentOrAsync),
            ]
            if key.animates {
                let processor = TimelineAnimatedImageProcessor()
                options += [.processor(processor), .cacheSerializer(processor)]
            } else {
                options += [.processor(DownsamplingImageProcessor(size: key.pixels))]
            }
            return options
        }

        private func restoreFromMemory() {
            guard let key = requestKey, let url = key.url else { return }
            let cache = mediaContext?.cache ?? .default
            if !requestFinished,
                let image = cache.retrieveImageInMemoryCache(
                    forKey: url.absoluteString, options: imageOptions(for: key)
                ), installImage(image, animates: key.animates)
            {
                requestFinished = true
            }
            guard decodedCGImage == nil else { return }
            // A different thumbnail size still has useful pixels. Never ask the
            // network or wait for disk just to restore a warm first frame.
            if let image = cache.retrieveImageInMemoryCache(
                forKey: TimelineImageMemory.firstFrameKey(for: url))
                ?? cache.retrieveImageInMemoryCache(
                    forKey: url.absoluteString,
                    options: [
                        .processor(DownsamplingImageProcessor(size: key.pixels)), .scaleFactor(1),
                    ])
                ?? cache.retrieveImageInMemoryCache(forKey: url.absoluteString)
            {
                installStatic(image)
            }
        }

        private func startMissingRequests() {
            guard active, !isLocal, !loading, !failed, !requestFinished,
                let key = requestKey, let url = key.url
            else { return }
            restoreFromMemory()
            guard !requestFinished else { return }
            let current = generation
            loading = true
            // The manager never mutates our views before the reuse guard runs. One
            // image supplies both the static frame and lazy animation, so a second
            // representation's failure cannot erase a successfully decoded frame.
            let task = KingfisherManager.shared.retrieveImage(
                with: url, options: imageOptions(for: key),
                downloadTaskUpdated: { [weak self] task in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current, self.requestKey == key,
                            self.loading
                        else {
                            task?.cancel()
                            return
                        }
                        self.imageTask = task
                    }
                }
            ) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current, self.requestKey == key else {
                        return
                    }
                    self.imageTask = nil
                    self.loading = false
                    self.requestFinished = true
                    switch result {
                    case .success(let value):
                        self.failed = !self.installImage(value.image, animates: key.animates)
                    case .failure:
                        self.failed = true
                    }
                    if self.failed && self.decodedCGImage == nil {
                        self.onLoadFailure?(String(localized: "Image download or decoding failed."))
                    }
                    self.setNeedsLayout()
                    self.refreshVisibility()
                }
            }
            if generation == current, requestKey == key, loading { imageTask = task }
        }

        @discardableResult
        private func installImage(_ image: UIImage, animates: Bool) -> Bool {
            guard installStatic(image) else { return false }
            if animates, let source = image.kf.frameSource, source.frameCount > 1 {
                let animated = makeAnimatedForeground()
                animated.image = image
                // Seed drawable content before hiding the static view. Leaving both
                // visible would show the first frame through later transparent frames.
                animated.layer.contents = decodedCGImage
                animated.layer.contentsGravity = .resize
                animated.isHidden = false
                foreground.isHidden = true
            } else {
                animatedForeground?.image = nil
                animatedForeground?.isHidden = true
                foreground.isHidden = false
            }
            return true
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

        @discardableResult
        private func installStatic(_ image: UIImage) -> Bool {
            guard let pixels = TimelineImageMemory.cgImage(image) else { return false }
            // An animation container is not itself a drawable UIImage. Retain a
            // plain first frame for immediate reuse and animation-buffer startup.
            let firstFrame = TimelineImageMemory.image(pixels)
            decodedImage = firstFrame
            foreground.image = firstFrame
            decodedCGImage = pixels
            failed = false
            if let url = requestKey?.url {
                (mediaContext?.cache ?? .default).store(
                    firstFrame, forKey: TimelineImageMemory.firstFrameKey(for: url), toDisk: false
                )
            }
            cancelBackdrop()
            backdrop.contents = nil
            backdropSize = .zero
            prepareBackdropIfNeeded()
            return true
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
            let hasImage = decodedCGImage != nil
            if hasImage != reportedImageAvailability {
                reportedImageAvailability = hasImage
                onImageAvailabilityChanged?(hasImage)
            }
            errorImage.isHidden = !showsPlaceholderChrome || !failed || hasImage
            let showProgress =
                showsPlaceholderChrome && !hasImage && !failed
                && (requestKey?.url != nil || loading)
            if showProgress && active {
                progress.startAnimating()
            } else {
                progress.stopAnimating()
            }
        }

        private func cancelRequests(preservingImages: Bool) {
            generation &+= 1
            imageTask?.cancel()
            imageTask = nil
            animatedForeground?.stopAnimating()
            if !preservingImages {
                foreground.image = nil
                foreground.isHidden = false
                animatedForeground?.image = nil
                animatedForeground?.isHidden = true
            }
            loading = isLocal && loading
        }

        private func clearPayload() {
            cancelRequests(preservingImages: false)
            cancelBackdrop()
            requestKey = nil
            mediaContext = nil
            decodedImage = nil
            decodedCGImage = nil
            isLocal = false
            loading = false
            failed = false
            requestFinished = false
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
            guard active, showsBackdrop, let image = decodedCGImage, bounds.width > 0,
                bounds.height > 0
            else { return }
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
                guard !Task.isCancelled, let self, self.backdropGeneration == current, self.active
                else { return }
                self.backdropWorker = nil
                self.backdropCompletion = nil
                self.backdrop.contentsScale = scale
                self.backdrop.contents = blurred
            }
        }

        nonisolated private static let backdropContext = CIContext(options: [
            .cacheIntermediates: false
        ])

        nonisolated private static func makeBackdrop(image: CGImage, size: CGSize, scale: CGFloat)
            -> CGImage?
        {
            guard !Task.isCancelled else { return nil }
            let width = ceil(size.width * scale)
            let height = ceil(size.height * scale)
            let expansion = 40 * scale
            let factor = max(
                (width + expansion) / CGFloat(image.width),
                (height + expansion) / CGFloat(image.height))
            let source = CIImage(cgImage: image)
                .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                .transformed(
                    by: CGAffineTransform(
                        translationX: (width - CGFloat(image.width) * factor) / 2,
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
