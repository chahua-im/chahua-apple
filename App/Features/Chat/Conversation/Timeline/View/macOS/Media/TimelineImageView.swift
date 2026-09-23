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
        private var imageTask: DownloadTask?
        private var loading = false
        private var failed = false
        private var requestFinished = false
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
        var onLoadFailure: ((String) -> Void)?

        var showsPlaceholderChrome = true {
            didSet { updateChrome() }
        }

        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            backdrop.actions = [
                "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
            ]
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
                imageTask?.cancel()
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
            self.contentMode = contentMode
            setBackdropEnabled(showsBlurredBackdrop)
            needsLayout = true
            refreshVisibility()
            updateChrome()
        }

        /// The pending tile owns its cancellable ImageIO task; the resulting first
        /// frame uses exactly the same fit/backdrop rendering as a delivered image.
        func configureLocal(
            image: CGImage?, contentMode: ContentMode, showsBlurredBackdrop: Bool, isLoading: Bool
        ) {
            clearPayload()
            isLocal = true
            self.contentMode = contentMode
            loading = isLoading
            failed = image == nil && !isLoading
            if let image {
                installStatic(
                    NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
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
            onLoadFailure = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [
                    NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                    NSWindow.didChangeOcclusionStateNotification,
                ] {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(windowVisibilityChanged), name: name,
                        object: window)
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
            let visible =
                requestedVisible && window != nil && !isHiddenOrHasHiddenAncestor
                && !visibleRect.isEmpty && window?.isVisible == true
                && window?.isMiniaturized == false
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
            if active && window?.occlusionState.contains(.visible) == true
                && animatedForeground?.isHidden == false
            {
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
                animatedForeground.frame = imageFrame(
                    for: animatedForeground.image?.size ?? decodedImage?.size ?? .zero)
            }
            progress.frame = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
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
            let scale = contentMode == .fit ? min(x, y) : max(x, y)
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
                    self.needsLayout = true
                    self.refreshVisibility()
                }
            }
            if generation == current, requestKey == key, loading { imageTask = task }
        }

        @discardableResult
        private func installImage(_ image: NSImage, animates: Bool) -> Bool {
            guard installStatic(image) else { return false }
            if animates, let source = image.kf.frameSource, source.frameCount > 1 {
                let animated = makeAnimatedForeground()
                animated.image = image
                // Seed drawable content before hiding the static view. Leaving both
                // visible would show the first frame through later transparent frames.
                animated.layer?.contents = decodedCGImage
                animated.layer?.contentsGravity = .resize
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
            view.imageScaling = .scaleAxesIndependently
            // The outer aspect-preserving frame is authoritative at every resize.
            // Avoid pre-scaling frames to a former row size inside the animator.
            view.needsPrescaling = false
            view.isHidden = true
            addSubview(view, positioned: .above, relativeTo: foreground)
            animatedForeground = view
            return view
        }

        @discardableResult
        private func installStatic(_ image: NSImage) -> Bool {
            guard let pixels = TimelineImageMemory.cgImage(image) else { return false }
            // Retain a plain drawable first frame for immediate reuse and while the
            // animator's asynchronous frame buffer initializes.
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
            layer?.backgroundColor = enabled ? NSColor.black.cgColor : nil
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
            progress.isHidden = !showProgress || !active
            if showProgress && active {
                progress.startAnimation(nil)
            } else {
                progress.stopAnimation(nil)
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
