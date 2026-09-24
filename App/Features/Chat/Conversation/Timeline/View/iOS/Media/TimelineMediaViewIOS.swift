#if os(iOS)
    import ChahuaAPI
    import ImageIO
    import UIKit

    /// UIKit composition is required to keep media under native row reuse and the
    /// timeline's measured geometry, without a SwiftUI host/AttributeGraph per row.
    /// Decoding and animation share the account cache and never resize the tiles.
    @MainActor
    final class TimelineMediaView: UIView {
        private var binding: TimelineRowBinding?
        private var tiles: [TimelineMediaTileView] = []
        private var itemFrames: [CGRect] = []
        private var visible = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
            didSet {
                for tile in tiles { tile.accessibilityCustomActions = accessibilityCustomActions }
            }
        }

        func bind(_ binding: TimelineRowBinding) {
            self.binding = binding
            guard case .message(let row) = binding.presentation.row,
                let mediaFrame = binding.layout.frames[.media],
                row.entry.remoteMessage?.isDeleted != true
            else {
                clearTiles(after: 0)
                itemFrames = []
                return
            }
            let environment = binding.presentation.environment
            if row.entry.messageType == .sticker {
                itemFrames = [CGRect(origin: .zero, size: mediaFrame.size)]
                let tile = tile(at: 0)
                tile.frame = itemFrames[0]
                tile.configureSticker(
                    row.entry.sticker, displayScale: environment.displayScale,
                    captionSize: environment.captionSize, mediaContext: binding.mediaContext,
                    canOpen: !binding.context.isInteractionPreview
                        && binding.actions.openSticker != nil)
                tile.onOpen = { [weak self] in self?.openSticker() }
                tile.setVisible(visible)
                clearTiles(after: 1)
            } else if row.entry.messageType == .text {
                let pending: [LocalOutgoingAttachment]
                if case .pending(let message) = row.entry {
                    pending = message.attachments
                } else {
                    pending = []
                }
                let attachments = row.entry.remoteMessage?.attachments ?? []
                let count = pending.isEmpty ? attachments.count : pending.count
                itemFrames =
                    count == 1
                    ? [CGRect(origin: .zero, size: mediaFrame.size)]
                    : Array(binding.layout.mediaFrames.prefix(min(6, count)))
                for index in itemFrames.indices {
                    let tile = tile(at: index)
                    tile.frame = itemFrames[index]
                    let overflow = index == 5 && count > 6 ? count - 5 : 0
                    if !pending.isEmpty {
                        tile.configurePending(
                            pending[index], gallery: count > 1, overflow: overflow,
                            captionSize: environment.captionSize,
                            canOpen: !binding.context.isInteractionPreview
                                && binding.actions.openMedia != nil)
                    } else {
                        tile.configureRemote(
                            attachments[index], gallery: count > 1, overflow: overflow,
                            displayScale: environment.displayScale,
                            captionSize: environment.captionSize,
                            mediaContext: binding.mediaContext,
                            canOpen: !binding.context.isInteractionPreview
                                && binding.actions.openMedia != nil)
                    }
                    tile.onOpen = { [weak self] in self?.openAttachment(at: index) }
                    tile.setVisible(visible)
                }
                clearTiles(after: itemFrames.count)
            } else {
                itemFrames = []
                clearTiles(after: 0)
            }
            setNeedsLayout()
        }

        func clear() {
            binding = nil
            visible = false
            itemFrames = []
            clearTiles(after: 0)
        }

        func setVisible(_ visible: Bool) {
            self.visible = visible
            for tile in tiles where !tile.isHidden { tile.setVisible(visible) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            for (index, frame) in itemFrames.enumerated() where index < tiles.count {
                tiles[index].frame = frame
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            for tile in tiles where !tile.isHidden { tile.setVisible(visible) }
        }

        private func tile(at index: Int) -> TimelineMediaTileView {
            while tiles.count <= index {
                let tile = TimelineMediaTileView(frame: .zero)
                tile.accessibilityCustomActions = accessibilityCustomActions
                tiles.append(tile)
                addSubview(tile)
            }
            let tile = tiles[index]
            tile.isHidden = false
            return tile
        }

        private func clearTiles(after count: Int) {
            for index in count..<tiles.count {
                tiles[index].clear()
                tiles[index].isHidden = true
            }
        }

        private func openAttachment(at index: Int) {
            guard let binding, !binding.context.isInteractionPreview,
                let action = binding.actions.openMedia,
                case .message(let row) = binding.presentation.row,
                let gallery = MessageImageGallery(entry: row.entry, attachmentIndex: index)
            else { return }
            action(gallery)
        }

        private func openSticker() {
            guard let binding, !binding.context.isInteractionPreview,
                case .message(let row) = binding.presentation.row,
                row.entry.remoteMessage?.isDeleted != true, let sticker = row.entry.sticker
            else { return }
            binding.actions.openSticker?(sticker.id)
        }
    }

    @MainActor
    private final class TimelineMediaTileView: UIControl {
        var onOpen: (() -> Void)? {
            didSet { updateTapMarker() }
        }

        private let surface = UIView(frame: .zero)
        private let imageView = TimelineImageView(frame: .zero)
        private var stickerView: StickerMediaSurfaceView?
        private let warningSymbol = UIImageView(frame: .zero)
        private let warningLabel = UILabel(frame: .zero)
        private let playSymbol = UIImageView(image: UIImage(systemName: "play.fill"))
        private let playBackground = UIView(frame: .zero)
        private var overflowBlur: UIVisualEffectView?
        private var overflowAnimator: UIViewPropertyAnimator?
        private let overflowShade = UIView(frame: .zero)
        private let overflowLabel = UILabel(frame: .zero)
        private let tapMarker = MessageRowGestureMarker(frame: .zero)
        private var localPath: String?
        private var localAttachmentGeneration: String?
        private var localImage: CGImage?
        private var localFailed = false
        private var localWorker: Task<CGImage?, Never>?
        private var localCompletion: Task<Void, Never>?
        private var localGeneration: UInt64 = 0
        private var requestedVisible = false
        private var active = false
        private var gallery = false
        private var captionSize: CGFloat = 12
        private var overflowCount = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isAccessibilityElement = true
            surface.clipsToBounds = true
            surface.isUserInteractionEnabled = false
            addSubview(surface)
            surface.addSubview(imageView)
            warningSymbol.contentMode = .scaleAspectFit
            surface.addSubview(warningSymbol)
            configureLabel(warningLabel)
            warningLabel.numberOfLines = 2
            surface.addSubview(warningLabel)
            playBackground.backgroundColor = .black.withAlphaComponent(0.5)
            playBackground.layer.cornerRadius = 22
            surface.addSubview(playBackground)
            playSymbol.tintColor = .white
            playSymbol.contentMode = .scaleAspectFit
            surface.addSubview(playSymbol)
            overflowShade.backgroundColor = .black.withAlphaComponent(0.4)
            overflowShade.isUserInteractionEnabled = false
            addSubview(overflowShade)
            configureLabel(overflowLabel)
            overflowLabel.font = .systemFont(ofSize: 32, weight: .semibold)
            overflowLabel.textColor = .white
            overflowLabel.layer.shadowColor = UIColor.black.cgColor
            overflowLabel.layer.shadowOpacity = 0.5
            overflowLabel.layer.shadowRadius = 3
            overflowLabel.layer.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(overflowLabel)
            tapMarker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(tapMarker)
            addTarget(self, action: #selector(activate), for: .touchUpInside)
            for name in [
                UIApplication.didBecomeActiveNotification,
                UIApplication.willResignActiveNotification,
                UIApplication.didEnterBackgroundNotification, UIScene.didActivateNotification,
                UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(visibilityChanged), name: name, object: nil)
            }
            resetChrome()
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            localWorker?.cancel()
            localCompletion?.cancel()
            NotificationCenter.default.removeObserver(self)
            MainActor.assumeIsolated { overflowAnimator?.stopAnimation(true) }
        }

        func configureRemote(
            _ attachment: AttachmentResponse, gallery: Bool, overflow: Int, displayScale: CGFloat,
            captionSize: CGFloat, mediaContext: AppMediaContext?, canOpen: Bool
        ) {
            clearSticker()
            discardLocal()
            self.gallery = gallery
            self.captionSize = captionSize
            resetChrome()
            let video = attachment.kind.hasPrefix("video/")
            configureSurface(gallery: gallery, video: video, overflow: overflow)
            if video {
                imageView.clear()
                imageView.isHidden = true
                showWarning(
                    symbol: "video.slash",
                    label: AppLanguage.localized("Video preview unavailable"),
                    color: .white.withAlphaComponent(0.8))
            } else {
                imageView.configure(
                    url: URL(string: attachment.url), contentMode: gallery ? .fill : .fit,
                    animates: RemoteImageFormat.isAnimated(contentType: attachment.kind),
                    showsBlurredBackdrop: !gallery,
                    thumbnailPixelSize: pixelSize(displayScale), mediaContext: mediaContext)
            }
            isEnabled = canOpen && attachment.kind.lowercased().hasPrefix("image/")
            accessibilityTraits = isEnabled ? .button : .image
            accessibilityLabel =
                video
                ? AppLanguage.localized("Video preview unavailable")
                : isEnabled ? AppLanguage.localized("Open image") : AppLanguage.localized("Image")
            updateTapMarker()
            setNeedsLayout()
        }

        func configurePending(
            _ attachment: LocalOutgoingAttachment, gallery: Bool, overflow: Int,
            captionSize: CGFloat, canOpen: Bool
        ) {
            clearSticker()
            let changed =
                localPath != attachment.previewPath
                || localAttachmentGeneration != attachment.generation
            let placementChanged = self.gallery != gallery
            self.gallery = gallery
            self.captionSize = captionSize
            resetChrome()
            let video = attachment.mimeType.hasPrefix("video/")
            configureSurface(gallery: gallery, video: video, overflow: overflow)
            if changed {
                discardLocal()
                localPath = attachment.previewPath
                localAttachmentGeneration = attachment.generation
                imageView.configureLocal(
                    image: nil, contentMode: gallery ? .fill : .fit, showsBlurredBackdrop: !gallery,
                    isLoading: true)
            } else if placementChanged {
                imageView.configureLocal(
                    image: localImage, contentMode: gallery ? .fill : .fit,
                    showsBlurredBackdrop: !gallery,
                    isLoading: localImage == nil && !localFailed)
            }
            playBackground.isHidden = !video
            playSymbol.isHidden = !video
            isEnabled = canOpen && attachment.mimeType.lowercased().hasPrefix("image/")
            accessibilityTraits = isEnabled ? .button : .image
            accessibilityLabel = attachment.fileName
            setNeedsLayout()
            refreshVisibility()
        }

        func configureSticker(
            _ sticker: MessageStickerResponse?, displayScale: CGFloat, captionSize: CGFloat,
            mediaContext: AppMediaContext?, canOpen: Bool
        ) {
            discardLocal()
            imageView.clear()
            gallery = false
            self.captionSize = captionSize
            resetChrome()
            configureSurface(gallery: false, video: false, overflow: 0)
            surface.backgroundColor = .clear
            layer.cornerRadius = 8
            imageView.isHidden = true
            if let sticker {
                let view: StickerMediaSurfaceView
                if let stickerView {
                    view = stickerView
                } else {
                    view = StickerMediaSurfaceView(frame: bounds)
                    view.isAccessibilityElement = false
                    surface.addSubview(view)
                    stickerView = view
                }
                view.isHidden = false
                view.onError = { [weak self] in self?.accessibilityValue = $0 }
                view.configure(
                    media: sticker.media, emoji: sticker.emoji, displayScale: displayScale,
                    mediaContext: mediaContext)
            } else {
                clearSticker()
                showWarning(
                    symbol: "photo.badge.exclamationmark",
                    label: AppLanguage.localized("Sticker data is missing."), color: .secondaryLabel
                )
            }
            isEnabled = canOpen && sticker != nil
            accessibilityTraits = isEnabled ? .button : .image
            accessibilityLabel =
                (sticker?.name).flatMap { $0.isEmpty ? nil : $0 }
                ?? (sticker?.emoji).flatMap { $0.isEmpty ? nil : $0 }
                ?? AppLanguage.localized("Sticker")
            accessibilityHint = isEnabled ? AppLanguage.localized("Opens sticker pack") : nil
            updateTapMarker()
            setNeedsLayout()
        }

        private func clearSticker() {
            stickerView?.clear()
            stickerView?.isHidden = true
            accessibilityHint = nil
            accessibilityValue = nil
        }

        func clear() {
            discardLocal()
            clearSticker()
            imageView.clear()
            requestedVisible = false
            active = false
            isEnabled = false
            onOpen = nil
            overflowCount = 0
            stopOverflowBlur()
            resetChrome()
            accessibilityLabel = nil
        }

        func setVisible(_ visible: Bool) {
            requestedVisible = visible
            refreshVisibility()
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard isEnabled, !isHidden, alpha > 0, self.point(inside: point, with: event) else {
                return nil
            }
            return self
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
                active = false
                cancelLocal()
                imageView.setVisible(false)
                stickerView?.setVisible(false)
                stopOverflowBlur()
            default:
                refreshVisibility()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            surface.frame = bounds
            imageView.frame = bounds
            stickerView?.frame = bounds
            overflowBlur?.frame = bounds
            overflowShade.frame = bounds
            overflowLabel.frame = CGRect(x: 0, y: bounds.midY - 21, width: bounds.width, height: 42)
            tapMarker.frame = bounds
            playBackground.frame = CGRect(
                x: bounds.midX - 22, y: bounds.midY - 22, width: 44, height: 44)
            playSymbol.frame = CGRect(
                x: bounds.midX - 10, y: bounds.midY - 12, width: 24, height: 24)
            let labelHeight = min(bounds.height, ceil(captionSize * 1.4) * 2)
            warningLabel.frame = CGRect(
                x: 8, y: bounds.midY + 5, width: max(0, bounds.width - 16), height: labelHeight)
            warningSymbol.frame = CGRect(
                x: bounds.midX - 12, y: bounds.midY - 27, width: 24, height: 24)
            refreshVisibility()
        }

        override func accessibilityActivate() -> Bool {
            guard isEnabled, onOpen != nil else { return false }
            activate()
            return true
        }

        @objc private func activate() {
            guard isEnabled else { return }
            onOpen?()
        }

        private func updateTapMarker() {
            if isEnabled, onOpen != nil {
                tapMarker.configure(.tap { [weak self] in self?.activate() })
            } else {
                tapMarker.stop()
            }
        }

        private func configureLabel(_ label: UILabel) {
            label.textAlignment = .center
            label.lineBreakMode = .byWordWrapping
            label.isAccessibilityElement = false
        }

        private func pixelSize(_ scale: CGFloat) -> CGSize {
            CGSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
        }

        private func configureSurface(gallery: Bool, video: Bool, overflow: Int) {
            layer.cornerRadius = 0
            surface.backgroundColor =
                gallery && !video
                ? UIColor(red: 244 / 255, green: 244 / 255, blue: 245 / 255, alpha: 1) : .black
            overflowCount = overflow
            if overflow == 0 { stopOverflowBlur() }
            overflowShade.isHidden = overflow == 0
            overflowLabel.isHidden = overflow == 0
            overflowLabel.text = overflow > 0 ? "+\(overflow)" : nil
        }

        private func startOverflowBlurIfNeeded() {
            guard overflowCount > 0, overflowAnimator == nil else { return }
            let blur: UIVisualEffectView
            if let overflowBlur {
                blur = overflowBlur
            } else {
                blur = UIVisualEffectView(effect: nil)
                blur.isUserInteractionEnabled = false
                insertSubview(blur, aboveSubview: surface)
                overflowBlur = blur
            }
            blur.frame = bounds
            blur.isHidden = false
            // UIKit does not support AppKit's CALayer CIFilter composition. A paused
            // native blur transition keeps the overflow surface lightly blurred,
            // including animated frames, without copying/rasterizing it every tick.
            let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
                blur.effect = UIBlurEffect(style: .regular)
            }
            animator.pausesOnCompletion = true
            animator.startAnimation()
            animator.pauseAnimation()
            animator.fractionComplete = 0.12
            overflowAnimator = animator
        }

        private func stopOverflowBlur() {
            overflowAnimator?.stopAnimation(true)
            overflowAnimator = nil
            overflowBlur?.effect = nil
            overflowBlur?.isHidden = true
        }

        private func resetChrome() {
            imageView.isHidden = false
            warningSymbol.isHidden = true
            warningLabel.isHidden = true
            warningLabel.text = nil
            playSymbol.isHidden = true
            playBackground.isHidden = true
            overflowShade.isHidden = true
            overflowLabel.isHidden = true
        }

        private func showWarning(symbol: String, label: String, color: UIColor) {
            warningSymbol.image = UIImage(systemName: symbol)
            warningSymbol.tintColor = color
            warningSymbol.isHidden = false
            warningLabel.font = .systemFont(ofSize: captionSize)
            warningLabel.textColor = color
            warningLabel.text = label
            warningLabel.isHidden = false
        }

        private func refreshVisibility() {
            let visible = requestedVisible && timelineMediaIsVisible
            if active != visible {
                active = visible
                if !visible {
                    cancelLocal()
                    stopOverflowBlur()
                }
            }
            imageView.setVisible(visible)
            stickerView?.setVisible(visible)
            if visible {
                startLocalIfNeeded()
                startOverflowBlurIfNeeded()
            }
        }

        private func startLocalIfNeeded() {
            guard active, let path = localPath, localImage == nil, !localFailed, localWorker == nil
            else { return }
            let current = localGeneration
            let worker = Task.detached(priority: .utility) { () -> CGImage? in
                guard !Task.isCancelled,
                    let source = CGImageSourceCreateWithURL(
                        URL(fileURLWithPath: path) as CFURL, nil)
                else { return nil }
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: 640,
                    ] as CFDictionary)
                return Task.isCancelled ? nil : image
            }
            localWorker = worker
            localCompletion = Task { [weak self] in
                let image = await worker.value
                guard !Task.isCancelled, let self, self.localGeneration == current,
                    self.localPath == path, self.active
                else { return }
                self.localWorker = nil
                self.localCompletion = nil
                self.localImage = image
                self.localFailed = image == nil
                self.imageView.configureLocal(
                    image: image, contentMode: self.gallery ? .fill : .fit,
                    showsBlurredBackdrop: !self.gallery, isLoading: false)
                self.imageView.setVisible(self.active)
            }
        }

        private func cancelLocal() {
            localGeneration &+= 1
            localWorker?.cancel()
            localWorker = nil
            localCompletion?.cancel()
            localCompletion = nil
        }

        private func discardLocal() {
            guard localPath != nil else { return }
            cancelLocal()
            localPath = nil
            localAttachmentGeneration = nil
            localImage = nil
            localFailed = false
        }
    }
#endif
