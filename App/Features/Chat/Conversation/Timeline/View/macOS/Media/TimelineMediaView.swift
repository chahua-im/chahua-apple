#if os(macOS)
import AppKit
import ChahuaAPI
import CoreImage
import ImageIO

/// The layout engine supplies every tile rectangle. This native composition keeps
/// media out of per-row SwiftUI hosting and shares the account's existing image cache.
@MainActor
final class TimelineMediaView: NSView {
    private var binding: TimelineRowBinding?
    private var tiles: [TimelineMediaTileView] = []
    private var itemFrames: [CGRect] = []
    private var visible = false

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func bind(_ binding: TimelineRowBinding) {
        self.binding = binding
        guard case .message(let row) = binding.presentation.row,
              let mediaFrame = binding.layout.frames[.media],
              row.entry.remoteMessage?.isDeleted != true else {
            clearTiles(after: 0)
            itemFrames = []
            return
        }
        let environment = binding.presentation.environment
        if row.entry.messageType == .sticker {
            itemFrames = [CGRect(origin: .zero, size: mediaFrame.size)]
            let tile = tile(at: 0)
            tile.frame = itemFrames[0]
            tile.configureSticker(row.entry.remoteMessage?.sticker, displayScale: environment.displayScale,
                                  captionSize: environment.captionSize, mediaContext: binding.mediaContext)
            tile.setVisible(visible)
            clearTiles(after: 1)
        } else if row.entry.messageType == .text {
            let pending: [LocalOutgoingAttachment]
            if case .pending(let message) = row.entry { pending = message.attachments } else { pending = [] }
            let attachments = row.entry.remoteMessage?.attachments ?? []
            let count = pending.isEmpty ? attachments.count : pending.count
            itemFrames = count == 1 ? [CGRect(origin: .zero, size: mediaFrame.size)] : Array(binding.layout.mediaFrames.prefix(min(6, count)))
            for index in itemFrames.indices {
                let tile = tile(at: index)
                tile.frame = itemFrames[index]
                let overflow = index == 5 && count > 6 ? count - 5 : 0
                if !pending.isEmpty {
                    tile.configurePending(pending[index], gallery: count > 1, overflow: overflow,
                                          captionSize: environment.captionSize)
                } else {
                    tile.configureRemote(attachments[index], gallery: count > 1, overflow: overflow,
                                         displayScale: environment.displayScale, captionSize: environment.captionSize,
                                         mediaContext: binding.mediaContext, canOpen: binding.actions.openMedia != nil)
                    tile.onOpen = { [weak self] in self?.openAttachment(at: index) }
                }
                tile.setVisible(visible)
            }
            clearTiles(after: itemFrames.count)
        } else {
            itemFrames = []
            clearTiles(after: 0)
        }
        needsLayout = true
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

    override func layout() {
        super.layout()
        for (index, frame) in itemFrames.enumerated() where index < tiles.count {
            tiles[index].frame = frame
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for tile in tiles where !tile.isHidden { tile.setVisible(visible) }
    }

    private func tile(at index: Int) -> TimelineMediaTileView {
        while tiles.count <= index {
            let tile = TimelineMediaTileView(frame: .zero)
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
        guard let binding, let action = binding.actions.openMedia,
              case .message(let row) = binding.presentation.row,
              row.entry.messageType == .text,
              let message = row.entry.remoteMessage, !message.isDeleted,
              message.attachments.indices.contains(index) else { return }
        let attachment = message.attachments[index]
        guard !attachment.kind.hasPrefix("video/") else { return }
        action(message.id, message.attachments, attachment.id)
    }
}

@MainActor
private final class TimelineMediaTileView: NSButton {
    var onOpen: (() -> Void)?

    private let surface = TimelineMediaSurface(frame: .zero)
    private let imageView = TimelineImageView(frame: .zero)
    private let warningSymbol = NSImageView(frame: .zero)
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let stickerEmoji = NSTextField(labelWithString: "")
    private let playSymbol = NSImageView(frame: .zero)
    private let playBackground = NSView(frame: .zero)
    private let overflowShade = NSView(frame: .zero)
    private let overflowLabel = NSTextField(labelWithString: "")
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
    private var isStickerFallback = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        imagePosition = .noImage
        bezelStyle = .regularSquare
        focusRingType = .exterior
        target = self
        action = #selector(activate)
        wantsLayer = true
        layer?.masksToBounds = true
        surface.wantsLayer = true
        surface.layer?.masksToBounds = true
        addSubview(surface)
        surface.addSubview(imageView)
        warningSymbol.imageScaling = .scaleProportionallyUpOrDown
        surface.addSubview(warningSymbol)
        configureLabel(warningLabel)
        surface.addSubview(warningLabel)
        configureLabel(stickerEmoji)
        stickerEmoji.font = .systemFont(ofSize: 34)
        surface.addSubview(stickerEmoji)
        playBackground.wantsLayer = true
        playBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        playBackground.layer?.cornerRadius = 22
        surface.addSubview(playBackground)
        playSymbol.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playSymbol.contentTintColor = .white
        playSymbol.imageScaling = .scaleProportionallyUpOrDown
        surface.addSubview(playSymbol)
        overflowShade.wantsLayer = true
        overflowShade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        addSubview(overflowShade)
        configureLabel(overflowLabel)
        overflowLabel.font = .systemFont(ofSize: 32, weight: .semibold)
        overflowLabel.textColor = .white
        overflowLabel.wantsLayer = true
        overflowLabel.layer?.shadowColor = NSColor.black.cgColor
        overflowLabel.layer?.shadowOpacity = 0.5
        overflowLabel.layer?.shadowRadius = 3
        overflowLabel.layer?.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(overflowLabel)
        resetChrome()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        localWorker?.cancel()
        localCompletion?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func configureRemote(_ attachment: AttachmentResponse, gallery: Bool, overflow: Int, displayScale: CGFloat,
                         captionSize: CGFloat, mediaContext: AppMediaContext?, canOpen: Bool) {
        discardLocal()
        self.gallery = gallery
        self.captionSize = captionSize
        resetChrome()
        let video = attachment.kind.hasPrefix("video/")
        configureSurface(gallery: gallery, video: video, overflow: overflow)
        if video {
            imageView.clear()
            imageView.isHidden = true
            showWarning(symbol: "video.slash", label: String(localized: "Video preview unavailable"), color: .white.withAlphaComponent(0.8))
        } else {
            imageView.configure(url: URL(string: attachment.url), contentMode: gallery ? .fill : .fit,
                                animates: RemoteImageFormat.isAnimated(contentType: attachment.kind),
                                showsBlurredBackdrop: !gallery,
                                thumbnailPixelSize: pixelSize(displayScale), mediaContext: mediaContext)
        }
        isEnabled = canOpen && !video
        setAccessibilityRole(isEnabled ? .button : .image)
        setAccessibilityLabel(video ? String(localized: "Video preview unavailable") : isEnabled ? String(localized: "Open image") : String(localized: "Image"))
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    func configurePending(_ attachment: LocalOutgoingAttachment, gallery: Bool, overflow: Int, captionSize: CGFloat) {
        let changed = localPath != attachment.previewPath || localAttachmentGeneration != attachment.generation
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
            imageView.configureLocal(image: nil, contentMode: gallery ? .fill : .fit, showsBlurredBackdrop: !gallery, isLoading: true)
        } else if placementChanged {
            imageView.configureLocal(image: localImage, contentMode: gallery ? .fill : .fit, showsBlurredBackdrop: !gallery,
                                     isLoading: localImage == nil && !localFailed)
        }
        playBackground.isHidden = !video
        playSymbol.isHidden = !video
        isEnabled = false
        onOpen = nil
        setAccessibilityRole(.image)
        setAccessibilityLabel(attachment.fileName)
        needsLayout = true
        refreshVisibility()
    }

    func configureSticker(_ sticker: MessageStickerResponse?, displayScale: CGFloat, captionSize: CGFloat,
                          mediaContext: AppMediaContext?) {
        discardLocal()
        self.captionSize = captionSize
        resetChrome()
        configureSurface(gallery: false, video: false, overflow: 0)
        surface.layer?.backgroundColor = nil
        layer?.cornerRadius = 8
        if let sticker, sticker.media.contentType.hasPrefix("image/") {
            imageView.configure(url: URL(string: sticker.media.url), contentMode: .fit,
                                animates: RemoteImageFormat.isAnimated(contentType: sticker.media.contentType),
                                showsBlurredBackdrop: false, thumbnailPixelSize: pixelSize(displayScale), mediaContext: mediaContext)
        } else {
            imageView.clear()
            imageView.isHidden = true
            isStickerFallback = true
            stickerEmoji.stringValue = sticker?.emoji ?? ""
            stickerEmoji.isHidden = stickerEmoji.stringValue.isEmpty
            showWarning(symbol: "photo.badge.exclamationmark", label: String(localized: "Sticker preview unavailable"), color: .secondaryLabelColor)
        }
        isEnabled = false
        onOpen = nil
        setAccessibilityRole(.image)
        setAccessibilityLabel(sticker?.name ?? sticker?.emoji ?? String(localized: "[Sticker]"))
        needsLayout = true
    }

    func clear() {
        discardLocal()
        imageView.clear()
        requestedVisible = false
        active = false
        onOpen = nil
        isEnabled = false
        resetChrome()
        setAccessibilityLabel(nil)
    }

    func setVisible(_ visible: Bool) {
        requestedVisible = visible
        refreshVisibility()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)), isEnabled else { return nil }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

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

    override func layout() {
        super.layout()
        surface.frame = bounds
        imageView.frame = bounds
        overflowShade.frame = bounds
        overflowLabel.frame = CGRect(x: 0, y: bounds.midY - 21, width: bounds.width, height: 42)
        playBackground.frame = CGRect(x: bounds.midX - 22, y: bounds.midY - 22, width: 44, height: 44)
        playSymbol.frame = CGRect(x: bounds.midX - 10, y: bounds.midY - 12, width: 24, height: 24)
        let lineHeight = ceil(captionSize * 1.4)
        let labelHeight = min(bounds.height, lineHeight * 2)
        warningLabel.frame = CGRect(x: 8, y: bounds.midY + 5, width: max(0, bounds.width - 16), height: labelHeight)
        warningSymbol.frame = CGRect(x: bounds.midX - 12, y: bounds.midY - 27, width: 24, height: 24)
        if isStickerFallback && !stickerEmoji.isHidden {
            stickerEmoji.frame = CGRect(x: 8, y: bounds.midY - 52, width: max(0, bounds.width - 16), height: 44)
            warningSymbol.frame = CGRect(x: 8, y: bounds.midY + 8, width: 16, height: 16)
            warningLabel.frame = CGRect(x: 28, y: bounds.midY + 5, width: max(0, bounds.width - 36), height: labelHeight)
        }
        refreshVisibility()
    }

    @objc private func activate() {
        guard isEnabled else { return }
        onOpen?()
    }

    private func configureLabel(_ label: NSTextField) {
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.alignment = .center
        label.cell?.lineBreakMode = .byWordWrapping
        label.setAccessibilityElement(false)
    }

    private func pixelSize(_ scale: CGFloat) -> CGSize {
        CGSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
    }

    private func configureSurface(gallery: Bool, video: Bool, overflow: Int) {
        layer?.cornerRadius = 0
        surface.layer?.backgroundColor = gallery && !video
            ? NSColor(srgbRed: 244.0 / 255, green: 244.0 / 255, blue: 245.0 / 255, alpha: 1).cgColor
            : NSColor.black.cgColor
        if (overflowCount > 0) != (overflow > 0) {
            surface.layer?.filters = overflow > 0
                ? [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 2])].compactMap { $0 }
                : nil
        }
        overflowCount = overflow
        overflowShade.isHidden = overflow == 0
        overflowLabel.isHidden = overflow == 0
        overflowLabel.stringValue = overflow > 0 ? "+\(overflow)" : ""
    }

    private func resetChrome() {
        imageView.isHidden = false
        warningSymbol.isHidden = true
        warningLabel.isHidden = true
        warningLabel.stringValue = ""
        stickerEmoji.isHidden = true
        stickerEmoji.stringValue = ""
        playSymbol.isHidden = true
        playBackground.isHidden = true
        overflowShade.isHidden = true
        overflowLabel.isHidden = true
        isStickerFallback = false
    }

    private func showWarning(symbol: String, label: String, color: NSColor) {
        warningSymbol.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        warningSymbol.contentTintColor = color
        warningSymbol.isHidden = false
        warningLabel.font = .systemFont(ofSize: captionSize)
        warningLabel.textColor = color
        warningLabel.stringValue = label
        warningLabel.isHidden = false
    }

    private func refreshVisibility() {
        let visible = requestedVisible && window != nil && !isHiddenOrHasHiddenAncestor
            && !visibleRect.isEmpty && window?.isVisible == true && window?.isMiniaturized == false
        if active != visible {
            active = visible
            if !visible { cancelLocal() }
        }
        imageView.setVisible(visible)
        if visible { startLocalIfNeeded() }
    }

    private func startLocalIfNeeded() {
        guard active, let path = localPath, localImage == nil, !localFailed, localWorker == nil else { return }
        let current = localGeneration
        let worker = Task.detached(priority: .utility) { () -> CGImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
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
            guard !Task.isCancelled, let self, self.localGeneration == current, self.localPath == path, self.active else { return }
            self.localWorker = nil
            self.localCompletion = nil
            self.localImage = image
            self.localFailed = image == nil
            self.imageView.configureLocal(image: image, contentMode: self.gallery ? .fill : .fit,
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

@MainActor
private final class TimelineMediaSurface: NSView {
    override var isFlipped: Bool { true }
}
#endif
