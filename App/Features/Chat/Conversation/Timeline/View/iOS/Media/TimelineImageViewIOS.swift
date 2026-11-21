#if os(iOS)
    import Combine
    import CoreImage
    import Kingfisher
    import UIKit

    /// Native image views avoid a SwiftUI subtree and its independent layout/lifecycle
    /// in every measured timeline row. Only pixels change after decoding; UIKit keeps
    /// the layout engine's frame and explicitly suspends work for nonvisible cells.
    /// Keep in-bubble failure recovery native as well; a per-row SwiftUI retry host
    /// would reintroduce that cost and compete with the row's media tap handling.
    @MainActor
    final class TimelineImageView: UIView {
        enum ScalingMode { case fit, fill }

        private struct RequestKey: Equatable, Sendable {
            let url: URL?
            let pixels: CGSize
            let context: ObjectIdentifier?
            let animates: Bool
            let isVideoPoster: Bool
            let isPreview: Bool
        }

        private let foreground = UIImageView(frame: .zero)
        private var animatedForeground: AnimatedImageView?
        private let backdrop = CALayer()
        private let backdropCover = CALayer()
        private let progress = UIActivityIndicatorView(style: .medium)
        private let errorImage = UIImageView(image: UIImage(systemName: "photo"))
        private var unavailableLabel: UILabel?
        private var retryButton: UIButton?
        private var retryUsesCompactLayout: Bool?
        private var requestKey: RequestKey?
        private var mediaContext: AppMediaContext?
        private var loadPolicy = MediaLoadPolicy.full
        private var policyObservation: AnyCancellable?
        private var scalingMode: ScalingMode = .fit
        private var showsBackdrop = false
        private var userInitiated = false
        private var requestedVisible = false
        private var active = false
        private var generation: UInt64 = 0
        private var imageTask: DownloadTask?
        private var posterProvider: VideoPoster?
        private var imagePreparation: DispatchWorkItem?
        private var preparationGeneration: UInt64 = 0
        // Bound preparation across rows, including warm originals. Cancellation
        // removes queued work rather than spawning a decoder for every reused row.
        nonisolated private static let preparationQueue = DispatchQueue(
            label: "app.chahua.timeline.display-preparation", qos: .userInitiated)
        // A running native preparation cannot be interrupted; request and
        // preparation fences also reject its result after cancellation or reuse.
        private var requestCacheKey: String?
        private var loading = false
        private var failed = false
        private var requestFinished = false
        private var isLocal = false
        private var decodedImage: UIImage?
        private var decodedCGImage: CGImage?
        private var attemptedMemoryFallback = false
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
                imagePreparation?.cancel()
                imageTask?.cancel()
                posterProvider?.cancel()
                animatedForeground?.stopAnimating()
            }
        }

        func configure(
            url: URL?, contentMode: ScalingMode, animates: Bool, showsBlurredBackdrop: Bool,
            thumbnailPixelSize: CGSize, mediaContext: AppMediaContext?, isVideoPoster: Bool = false,
            isPreview: Bool = false
        ) {
            let pixels =
                isVideoPoster
                ? VideoPoster.pixelSize
                : CGSize(
                    width: max(1, thumbnailPixelSize.width),
                    height: max(1, thumbnailPixelSize.height))
            let key = RequestKey(
                url: url, pixels: pixels, context: mediaContext.map(ObjectIdentifier.init),
                animates: animates && !isVideoPoster, isVideoPoster: isVideoPoster,
                isPreview: isPreview)
            if key != requestKey || isLocal {
                let sameMedia =
                    !isLocal && url != nil && requestKey?.url == url
                    && requestKey?.context == key.context
                    && requestKey?.isVideoPoster == isVideoPoster
                    && requestKey?.isPreview == isPreview
                if sameMedia {
                    cancelRequests(preservingImages: true)
                    requestFinished =
                        animates && requestKey?.animates == true && requestFinished && !failed
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
                loadPolicy = mediaContext?.loadPolicy ?? .cacheOnly
                if !sameMedia {
                    policyObservation = mediaContext?.loadPolicyChanges.sink { [weak self] policy in
                        self?.applyLoadPolicy(policy)
                    }
                }
                if let url {
                    if isVideoPoster {
                        let provider = VideoPoster(url: url)
                        posterProvider = provider
                        requestCacheKey = provider.cacheKey
                    } else {
                        requestCacheKey = url.absoluteString
                    }
                }
                failed = failed || url == nil || mediaContext == nil
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
            if let image {
                prepareImage(UIImage(cgImage: image), for: nil, completesRequest: false)
            }
            setBackdropEnabled(showsBlurredBackdrop)
            setNeedsLayout()
            refreshVisibility()
            updateChrome()
        }

        func setVisible(_ visible: Bool) {
            if requestedVisible == visible {
                guard active != (visible && timelineMediaIsVisible) else { return }
            }
            requestedVisible = visible
            refreshVisibility()
        }

        /// Explicit retries can load on restricted connections, but never bypass
        /// the context's cache-only account/offline policy.
        func retryLoad() {
            guard !isLocal, requestKey?.url != nil, mediaContext != nil else { return }
            cancelRequests(preservingImages: true)
            userInitiated = true
            failed = false
            requestFinished = false
            refreshVisibility()
            updateChrome()
        }

        @objc private func retryPressed() { retryLoad() }

        override var accessibilityElements: [Any]? {
            get {
                guard let retryButton, !retryButton.isHidden else { return [] }
                return [retryButton]
            }
            set {}
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard isUserInteractionEnabled, !isHidden, alpha > 0,
                self.point(inside: point, with: event),
                let retryButton, !retryButton.isHidden
            else { return nil }
            return retryButton.hitTest(convert(point, to: retryButton), with: event)
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
            if requestKey?.isVideoPoster == true {
                errorImage.frame = CGRect(x: 6, y: 6, width: 16, height: 16)
            } else {
                errorImage.frame = CGRect(
                    x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
            }
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

        private var allowsNetwork: Bool {
            loadPolicy.allowsNetwork(
                isVideo: requestKey?.isVideoPoster == true,
                isPreview: requestKey?.isPreview == true, userInitiated: userInitiated)
        }

        private func applyLoadPolicy(_ policy: MediaLoadPolicy) {
            let previous = allowsNetwork
            loadPolicy = policy
            guard previous != allowsNetwork, requestKey?.url != nil else { return }
            if loading { cancelRequests(preservingImages: true) }
            if failed {
                failed = false
                requestFinished = false
            }
            refreshVisibility()
        }

        private func imageOptions(
            for key: RequestKey, context: AppMediaContext
        ) -> KingfisherOptionsInfo {
            var options: KingfisherOptionsInfo = [
                .scaleFactor(1), .targetCache(context.cache),
                .downloader(context.downloader), .cacheOriginalImage,
                .callbackQueue(.mainCurrentOrAsync),
            ]
            if !allowsNetwork { options.append(.onlyFromCache) }
            if key.animates {
                let processor = TimelineAnimatedImageProcessor()
                options += [.processor(processor), .cacheSerializer(processor)]
            } else {
                options += [.processor(TimelineStaticImageProcessor(size: key.pixels))]
            }
            return options
        }

        private func displayFrameKey(for key: RequestKey, sized: Bool) -> String {
            let source = requestCacheKey ?? key.url?.absoluteString ?? ""
            let base = "app.chahua.timeline.ios-display-ready:\(source)"
            return sized
                ? "\(base):\(key.pixels):\(key.animates):\(key.isVideoPoster)" : base
        }

        private func restoreFromMemory() {
            guard let key = requestKey, let url = key.url, let cacheKey = requestCacheKey,
                let mediaContext, imagePreparation == nil
            else { return }
            let cache = mediaContext.cache
            let ready = cache.retrieveImageInMemoryCache(
                forKey: displayFrameKey(for: key, sized: true))
            if decodedCGImage == nil,
                let firstFrame = ready
                    ?? cache.retrieveImageInMemoryCache(
                        forKey: displayFrameKey(for: key, sized: false))
            {
                installStatic(firstFrame)
            }
            if !requestFinished,
                let image = cache.retrieveImageInMemoryCache(
                    forKey: cacheKey, options: imageOptions(for: key, context: mediaContext))
            {
                if let ready {
                    requestFinished = installImage(image, firstFrame: ready, animates: key.animates)
                } else {
                    prepareImage(image, for: key, completesRequest: true)
                }
                return
            }
            if ready != nil && !key.animates {
                requestFinished = true
                return
            }
            guard !key.isVideoPoster, decodedCGImage == nil, !attemptedMemoryFallback else {
                return
            }
            // Legacy/other-size/original cache entries are not necessarily decoded.
            // Keep them warm without drawing or re-encoding a full original on main.
            if let image = cache.retrieveImageInMemoryCache(
                forKey: TimelineImageMemory.firstFrameKey(for: url))
                ?? cache.retrieveImageInMemoryCache(
                    forKey: url.absoluteString,
                    options: [
                        .processor(DownsamplingImageProcessor(size: key.pixels)), .scaleFactor(1),
                    ])
                ?? cache.retrieveImageInMemoryCache(forKey: url.absoluteString)
            {
                attemptedMemoryFallback = true
                prepareImage(image, for: key, completesRequest: !key.animates)
            }
        }

        private func startMissingRequests() {
            guard active, !isLocal, !loading, !failed, !requestFinished,
                let key = requestKey, let url = key.url, let mediaContext
            else { return }
            restoreFromMemory()
            guard !requestFinished, imagePreparation == nil else { return }
            let source: Source
            if key.isVideoPoster {
                let provider = posterProvider ?? VideoPoster(url: url)
                posterProvider = provider
                source = .provider(provider)
            } else {
                source = .network(url)
            }
            let current = generation
            loading = true
            // The manager never mutates our views before the reuse guard runs. One
            // image supplies both the static frame and lazy animation, so a second
            // representation's failure cannot erase a successfully decoded frame.
            let task = KingfisherManager.shared.retrieveImage(
                with: source, options: imageOptions(for: key, context: mediaContext),
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
                },
                completionHandler: { [weak self] result in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == current, self.requestKey == key else {
                            return
                        }
                        self.imageTask = nil
                        self.posterProvider = nil
                        switch result {
                        case .success(let value):
                            self.prepareImage(value.image, for: key, completesRequest: true)
                            return
                        case .failure:
                            self.loading = false
                            self.requestFinished = true
                            self.failed = true
                        }
                        if self.failed && self.decodedCGImage == nil && self.allowsNetwork {
                            self.onLoadFailure?(
                                AppLanguage.localized("Image download or decoding failed."))
                        }
                        self.setNeedsLayout()
                        self.refreshVisibility()
                    }
                }
            )
            if generation == current, requestKey == key, loading { imageTask = task }
        }

        @discardableResult
        private func installImage(_ image: UIImage, firstFrame: UIImage, animates: Bool) -> Bool {
            guard installStatic(firstFrame) else { return false }
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

        private func prepareImage(
            _ image: UIImage, for key: RequestKey?, completesRequest: Bool
        ) {
            imagePreparation?.cancel()
            preparationGeneration &+= 1
            let preparation = preparationGeneration
            let current = generation
            if key != nil { loading = true }
            let work = DispatchWorkItem { [weak self] in
                let frame = TimelineImageMemory.displayReadyFrame(image, pixels: key?.pixels)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == current, self.requestKey == key,
                        self.preparationGeneration == preparation
                    else { return }
                    self.imagePreparation = nil
                    if key != nil { self.loading = false }
                    if let frame {
                        if let key {
                            guard let cache = self.mediaContext?.cache else { return }
                            cache.store(
                                frame, forKey: self.displayFrameKey(for: key, sized: true),
                                toDisk: false)
                            cache.store(
                                frame, forKey: self.displayFrameKey(for: key, sized: false),
                                toDisk: false)
                            if completesRequest {
                                self.requestFinished = true
                                self.failed = !self.installImage(
                                    image, firstFrame: frame, animates: key.animates)
                            } else {
                                self.installStatic(frame)
                            }
                        } else {
                            self.installStatic(frame)
                        }
                    } else if completesRequest {
                        self.requestFinished = true
                        self.failed = true
                        if self.decodedCGImage == nil && self.allowsNetwork {
                            self.onLoadFailure?(
                                AppLanguage.localized("Image download or decoding failed."))
                        }
                    }
                    self.setNeedsLayout()
                    self.refreshVisibility()
                }
            }
            imagePreparation = work
            Self.preparationQueue.async(execute: work)
        }

        @discardableResult
        private func installStatic(_ image: UIImage) -> Bool {
            // Only displayReadyFrame output (or its memory-cache entries) reaches
            // this boundary; never ask a lazy frame source for pixels on main.
            guard let pixels = image.cgImage else { return false }
            let firstFrame = image
            decodedImage = firstFrame
            foreground.image = firstFrame
            decodedCGImage = pixels
            failed = false
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
            let showUnavailable = showsPlaceholderChrome && failed && !hasImage
            let video = requestKey?.isVideoPoster == true
            let showRetry =
                showUnavailable && !isLocal && requestKey?.url != nil && mediaContext != nil
            if showRetry {
                let button = retryButton ?? makeRetryButton()
                let compact = bounds.width < 96 || bounds.height < (video ? 96 : 32)
                if retryUsesCompactLayout != compact {
                    var configuration = button.configuration
                    configuration?.title = compact ? nil : AppLanguage.localized("Retry")
                    configuration?.contentInsets = NSDirectionalEdgeInsets(
                        top: 0, leading: compact ? 0 : 8, bottom: 0, trailing: compact ? 0 : 8)
                    button.configuration = configuration
                    retryUsesCompactLayout = compact
                }
                let inset: CGFloat = min(4, max(0, min(bounds.width, bounds.height) / 8))
                let width = min(
                    max(0, bounds.width - inset * 2),
                    compact ? 28 : button.sizeThatFits(bounds.size).width)
                let height = min(32, max(0, bounds.height - inset * 2))
                button.frame = CGRect(
                    x: video ? inset : bounds.midX - width / 2,
                    y: video ? inset : bounds.midY - height / 2, width: width, height: height)
                button.isHidden = false
            } else {
                retryButton?.isHidden = true
            }
            let showText =
                showUnavailable && !isLocal && !allowsNetwork
                && bounds.width >= 96 && bounds.height >= (video ? 94 : 108)
            if showText {
                let label = unavailableLabel ?? makeUnavailableLabel()
                label.textColor = showsBackdrop ? .white : .secondaryLabel
                label.frame = CGRect(
                    x: 4, y: bounds.midY + (video ? 23 : 20),
                    width: bounds.width - 8, height: video ? 24 : 32)
                label.isHidden = false
            } else {
                unavailableLabel?.isHidden = true
            }
            errorImage.isHidden = !showUnavailable || showText || showRetry
            let showProgress =
                showsPlaceholderChrome && !hasImage && !failed
                && (isLocal ? loading : allowsNetwork && requestKey?.url != nil)
            if showProgress && active {
                progress.startAnimating()
            } else {
                progress.stopAnimating()
            }
        }

        private func makeUnavailableLabel() -> UILabel {
            let label = UILabel()
            label.text = AppLanguage.localized("Media not downloaded")
            label.font = .preferredFont(forTextStyle: .caption2)
            label.textAlignment = .center
            label.numberOfLines = 2
            label.isAccessibilityElement = false
            unavailableLabel = label
            addSubview(label)
            return label
        }

        private func makeRetryButton() -> UIButton {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.filled()
            configuration.title = AppLanguage.localized("Retry")
            configuration.image = UIImage(systemName: "arrow.clockwise")
            configuration.imagePadding = 4
            configuration.baseBackgroundColor = .darkGray
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            button.configuration = configuration
            button.accessibilityLabel = AppLanguage.localized("Retry")
            button.addTarget(self, action: #selector(retryPressed), for: .touchUpInside)
            retryButton = button
            addSubview(button)
            return button
        }

        private func cancelRequests(preservingImages: Bool) {
            generation &+= 1
            preparationGeneration &+= 1
            imagePreparation?.cancel()
            imagePreparation = nil
            attemptedMemoryFallback = false
            imageTask?.cancel()
            imageTask = nil
            posterProvider?.cancel()
            posterProvider = nil
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
            policyObservation = nil
            cancelBackdrop()
            requestKey = nil
            requestCacheKey = nil
            mediaContext = nil
            decodedImage = nil
            decodedCGImage = nil
            isLocal = false
            userInitiated = false
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
