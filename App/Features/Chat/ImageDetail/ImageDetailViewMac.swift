#if os(macOS)
    import AppKit
    import Combine
    import Kingfisher
    import QuartzCore
    import SwiftUI

    /// AppKit owns magnification, clip-view panning and gesture phases here: a SwiftUI
    /// drag layered over a scroll view cannot reliably keep paging out of a live pinch.
    struct ImageDetailPlatformView: NSViewRepresentable {
        let gallery: MessageImageGallery
        let mediaContext: AppMediaContext?
        let onDismiss: () -> Void

        func makeNSView(context: Context) -> MessageImageDetailMacView {
            MessageImageDetailMacView(
                gallery: gallery, mediaContext: mediaContext, onDismiss: onDismiss)
        }

        func updateNSView(_ nsView: MessageImageDetailMacView, context: Context) {
            nsView.onDismiss = onDismiss
        }

        static func dismantleNSView(_ nsView: MessageImageDetailMacView, coordinator: ()) {
            nsView.invalidate()
        }
    }

    @MainActor
    final class MessageImageDetailMacView: NSView {
        var onDismiss: () -> Void

        private enum DragAxis { case undecided, horizontal, vertical, pan }

        private let gallery: MessageImageGallery
        private let mediaContext: AppMediaContext?
        private let backdrop = NSView()
        private let viewport = MessageImageDetailMacContainer()
        private let chrome = MessageImageDetailMacContainer()
        private let closeButton = NSButton()
        private let previousButton = NSButton()
        private let nextButton = NSButton()
        private let countLabel = NSTextField(labelWithString: "")
        private let fileNameLabel = NSTextField(labelWithString: "")
        private var pages: [Int: MessageImageDetailMacPage] = [:]
        private var selectedIndex: Int
        private var dragAxis = DragAxis.undecided
        private var translation = CGPoint.zero
        private var displayOffset = CGPoint.zero
        private var velocity = CGPoint.zero
        private var lastTimestamp: TimeInterval = 0
        private var lastMousePoint: CGPoint?
        private var wheelEndTask: Task<Void, Never>?
        private var scrollPansImage = false
        private var isMagnifying = false
        private var isTransitioning = false
        private var isDismissing = false
        private var isInvalidated = false
        private var didDismiss = false
        private var didPresent = false
        private var animationGeneration = 0
        private weak var owningWindow: NSWindow?
        private weak var previousFirstResponder: NSResponder?

        private var activePage: MessageImageDetailMacPage? { pages[selectedIndex] }
        private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        private var pageStride: CGFloat { viewport.bounds.width + 32 }
        private var acceptsInteraction: Bool { !isInvalidated && !isDismissing && !isTransitioning }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { !isInvalidated && !isDismissing }
        override var mouseDownCanMoveWindow: Bool { false }

        init(
            gallery: MessageImageGallery, mediaContext: AppMediaContext?,
            onDismiss: @escaping () -> Void
        ) {
            self.gallery = gallery
            self.mediaContext = mediaContext
            self.onDismiss = onDismiss
            selectedIndex = gallery.selectedIndex
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            setAccessibilityElement(false)
            setAccessibilityRole(.group)
            setAccessibilityLabel(AppLanguage.localized("Image viewer"))
            appearance = NSAppearance(named: .darkAqua)

            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.97).cgColor
            backdrop.setAccessibilityHidden(true)
            addSubview(backdrop)
            viewport.wantsLayer = true
            viewport.layer?.masksToBounds = true
            viewport.setAccessibilityElement(false)
            viewport.setAccessibilityRole(.group)
            viewport.setAccessibilityIdentifier("image-detail-viewport")
            addSubview(viewport)
            chrome.setAccessibilityElement(false)
            addSubview(chrome)

            configureButton(
                closeButton, symbol: "xmark", label: AppLanguage.localized("Close image"),
                action: #selector(close))
            configureButton(
                previousButton, symbol: "chevron.left",
                label: AppLanguage.localized("Previous image"),
                action: #selector(previousImage))
            configureButton(
                nextButton, symbol: "chevron.right", label: AppLanguage.localized("Next image"),
                action: #selector(nextImage))
            countLabel.textColor = .white
            countLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
            countLabel.alignment = .center
            countLabel.setAccessibilityIdentifier("image-detail-position")
            chrome.addSubview(countLabel)
            fileNameLabel.textColor = .white.withAlphaComponent(0.8)
            fileNameLabel.font = .systemFont(ofSize: 13)
            fileNameLabel.alignment = .center
            fileNameLabel.lineBreakMode = .byTruncatingMiddle
            chrome.addSubview(fileNameLabel)
            closeButton.nextKeyView = previousButton
            previousButton.nextKeyView = nextButton
            nextButton.nextKeyView = closeButton

            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(accessibilityOptionsChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            refreshPages()
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            wheelEndTask?.cancel()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !isInvalidated, !didPresent else { return }
            didPresent = true
            owningWindow = window
            previousFirstResponder = window.firstResponder
            window.makeFirstResponder(self)
            layoutSubtreeIfNeeded()
            if !reduceMotion {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { animation in
                    animation.duration = 0.16
                    self.animator().alphaValue = 1
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { restoreFocus() }
            super.viewWillMove(toWindow: newWindow)
        }

        func invalidate() {
            guard !isInvalidated else { return }
            restoreFocus()
            isInvalidated = true
            animationGeneration += 1
            wheelEndTask?.cancel()
            wheelEndTask = nil
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            for page in pages.values { page.cancel() }
            pages.removeAll()
        }

        private func restoreFocus() {
            guard let window = owningWindow else { return }
            defer {
                owningWindow = nil
                previousFirstResponder = nil
            }
            guard
                window.firstResponder === self
                    || (window.firstResponder as? NSView)?.isDescendant(of: self) == true
            else { return }
            if let view = previousFirstResponder as? NSView, view.window === window,
                window.makeFirstResponder(view)
            {
                return
            }
            if let controller = previousFirstResponder as? NSViewController,
                controller.isViewLoaded, controller.view.window === window,
                window.makeFirstResponder(controller)
            {
                return
            }
            window.makeFirstResponder(nil)
        }

        private func configureButton(
            _ button: NSButton, symbol: String, label: String, action: Selector
        ) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 16, weight: .semibold)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = .white
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.8).cgColor
            button.layer?.cornerRadius = 20
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            chrome.addSubview(button)
        }

        private func refreshPages() {
            let first = max(0, selectedIndex - 1)
            let last = min(gallery.items.count - 1, selectedIndex + 1)
            for index in Array(pages.keys) where index < first || index > last {
                pages[index]?.cancel()
                pages.removeValue(forKey: index)?.removeFromSuperview()
            }
            for index in first...last {
                if pages[index] == nil {
                    let page = MessageImageDetailMacPage(
                        item: gallery.items[index], mediaContext: mediaContext)
                    page.onZoomChanged = { [weak self] in self?.updateControls() }
                    page.onRetry = { [weak self] in
                        guard let self else { return }
                        self.window?.makeFirstResponder(self)
                    }
                    pages[index] = page
                    viewport.addSubview(page)
                }
                pages[index]?.setActive(index == selectedIndex, reduceMotion: reduceMotion)
                pages[index]?.setAccessibilityHidden(index != selectedIndex)
            }
            updateControls()
            needsLayout = true
            layoutSubtreeIfNeeded()
        }

        private func updateControls() {
            let canPage = acceptsInteraction && !isMagnifying && activePage?.isAtFit == true
            previousButton.isEnabled = canPage && selectedIndex > 0
            nextButton.isEnabled = canPage && selectedIndex + 1 < gallery.items.count
            previousButton.isHidden = gallery.items.count == 1
            nextButton.isHidden = gallery.items.count == 1
            countLabel.stringValue = AppLanguage.localized(
                "\(selectedIndex + 1) of \(gallery.items.count)")
            fileNameLabel.stringValue = gallery.items[selectedIndex].fileName
            nextButton.nextKeyView =
                activePage?.retryButton.isHidden == false ? activePage?.retryButton : closeButton
            activePage?.retryButton.nextKeyView = closeButton
        }

        @objc private func accessibilityOptionsChanged() {
            for (index, page) in pages {
                page.setActive(index == selectedIndex, reduceMotion: reduceMotion)
            }
        }

        override func layout() {
            super.layout()
            guard !isInvalidated else { return }
            backdrop.frame = bounds
            chrome.frame = bounds
            viewport.frame = CGRect(
                x: 16, y: 64, width: max(1, bounds.width - 32), height: max(1, bounds.height - 120))
            closeButton.frame = CGRect(x: max(8, bounds.width - 56), y: 16, width: 40, height: 40)
            countLabel.frame = CGRect(x: 64, y: 27, width: max(0, bounds.width - 128), height: 22)
            previousButton.frame = CGRect(x: 16, y: bounds.midY - 20, width: 40, height: 40)
            nextButton.frame = CGRect(
                x: max(16, bounds.width - 56), y: bounds.midY - 20, width: 40, height: 40)
            fileNameLabel.frame = CGRect(
                x: 32, y: max(64, bounds.height - 37), width: max(0, bounds.width - 64), height: 20)
            placePages(animated: false)
        }

        private func placePages(animated: Bool) {
            for (index, page) in pages {
                let frame = CGRect(
                    x: CGFloat(index - selectedIndex) * pageStride + displayOffset.x,
                    y: displayOffset.y, width: viewport.bounds.width, height: viewport.bounds.height
                )
                if animated { page.animator().frame = frame } else { page.frame = frame }
            }
        }

        // Events belong only to this overlay. Native buttons retain their hit targets;
        // all image/clip descendants route through one directional gesture owner.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            var candidate: NSView? = hit
            while let view = candidate, view !== self {
                if let button = view as? NSButton { return button }
                candidate = view.superview
            }
            return self
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func keyDown(with event: NSEvent) {
            if handleKey(event) { return }
            if event.keyCode == 48 {
                if event.modifierFlags.contains(.shift) {
                    window?.selectPreviousKeyView(self)
                } else {
                    window?.selectNextKeyView(self)
                }
                return
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.window === window,
                window?.firstResponder === self
                    || (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
            else {
                return super.performKeyEquivalent(with: event)
            }
            return handleKey(event) || super.performKeyEquivalent(with: event)
        }

        private func handleKey(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return false
            }
            switch event.keyCode {
            case 53: dismiss(downward: false)
            case 123: changePage(by: -1)
            case 124: changePage(by: 1)
            default: return false
            }
            return true
        }

        override func cancelOperation(_ sender: Any?) { dismiss(downward: false) }
        @objc private func close() { dismiss(downward: false) }
        @objc private func previousImage() { changePage(by: -1) }
        @objc private func nextImage() { changePage(by: 1) }

        override func magnify(with event: NSEvent) {
            guard acceptsInteraction, let page = activePage, page.hasImage else { return }
            if !isMagnifying {
                resetDrag()
                displayOffset = .zero
                placePages(animated: false)
                backdrop.alphaValue = 1
                chrome.alphaValue = 1
                isMagnifying = true
            }
            page.scrollView.magnify(with: event)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                isMagnifying = false
            }
            updateControls()
        }

        override func smartMagnify(with event: NSEvent) {
            guard acceptsInteraction, !isMagnifying else { return }
            activePage?.toggleZoom(at: event.locationInWindow, reduceMotion: reduceMotion)
            updateControls()
        }

        override func scrollWheel(with event: NSEvent) {
            guard acceptsInteraction, !isMagnifying, let page = activePage else { return }
            if event.phase.contains(.mayBegin) { return }
            if event.phase.contains(.began) {
                resetDrag()
                scrollPansImage = !page.isAtFit
            }
            if !page.isAtFit || scrollPansImage {
                scrollPansImage = true
                page.scrollView.scrollWheel(with: event)
                if event.momentumPhase.contains(.ended)
                    || (event.phase.isEmpty && event.momentumPhase.isEmpty)
                {
                    scrollPansImage = false
                }
                return
            }
            // The gesture commits on finger lift. Its inertial tail must never page
            // a second image or turn a just-finished horizontal swipe into dismissal.
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.cancelled) {
                finishDrag(cancelled: true)
                return
            }
            if event.phase.contains(.ended) {
                if event.timestamp - lastTimestamp > 0.12 { velocity = .zero }
                finishDrag(cancelled: false)
                return
            }
            guard event.hasPreciseScrollingDeltas else { return }
            updateDrag(
                delta: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
                timestamp: event.timestamp)
            if event.phase.isEmpty {
                wheelEndTask?.cancel()
                wheelEndTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    self?.finishDrag(cancelled: false)
                }
            }
        }

        override func swipe(with event: NSEvent) {
            guard acceptsInteraction, !isMagnifying, activePage?.isAtFit == true else { return }
            if abs(event.deltaX) > abs(event.deltaY), event.deltaX != 0 {
                changePage(by: event.deltaX > 0 ? -1 : 1)
            } else if event.deltaY > 0 {
                dismiss(downward: true)
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard acceptsInteraction, !isMagnifying else { return }
            window?.makeFirstResponder(self)
            resetDrag()
            if event.clickCount == 2 {
                activePage?.toggleZoom(at: event.locationInWindow, reduceMotion: reduceMotion)
                updateControls()
                return
            }
            dragAxis = activePage?.isAtFit == false ? .pan : .undecided
            lastMousePoint = convert(event.locationInWindow, from: nil)
            lastTimestamp = event.timestamp
        }

        override func mouseDragged(with event: NSEvent) {
            guard acceptsInteraction, let last = lastMousePoint else { return }
            let point = convert(event.locationInWindow, from: nil)
            lastMousePoint = point
            let delta = CGPoint(x: point.x - last.x, y: point.y - last.y)
            if dragAxis == .pan {
                activePage?.pan(by: delta)
            } else {
                updateDrag(delta: delta, timestamp: event.timestamp)
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard lastMousePoint != nil else { return }
            if event.timestamp - lastTimestamp > 0.12 { velocity = .zero }
            lastMousePoint = nil
            if dragAxis == .pan { resetDrag() } else { finishDrag(cancelled: false) }
        }

        private func resetDrag() {
            wheelEndTask?.cancel()
            wheelEndTask = nil
            dragAxis = .undecided
            translation = .zero
            velocity = .zero
            lastTimestamp = 0
            lastMousePoint = nil
        }

        private func updateDrag(delta: CGPoint, timestamp: TimeInterval) {
            guard activePage?.isAtFit == true else { return }
            translation.x += delta.x
            translation.y += delta.y
            if lastTimestamp > 0 {
                let interval = max(1.0 / 240, timestamp - lastTimestamp)
                velocity = CGPoint(x: delta.x / interval, y: delta.y / interval)
            }
            lastTimestamp = timestamp
            if dragAxis == .undecided, max(abs(translation.x), abs(translation.y)) > 7 {
                dragAxis = abs(translation.x) > abs(translation.y) ? .horizontal : .vertical
            }
            switch dragAxis {
            case .horizontal:
                let beyondEnd =
                    (translation.x > 0 && selectedIndex == 0)
                    || (translation.x < 0 && selectedIndex == gallery.items.count - 1)
                displayOffset = CGPoint(x: translation.x * (beyondEnd ? 0.22 : 1), y: 0)
            case .vertical:
                displayOffset = CGPoint(
                    x: 0, y: translation.y >= 0 ? translation.y : translation.y * 0.15)
            case .undecided, .pan: return
            }
            placePages(animated: false)
            let progress = min(1, max(0, displayOffset.y) / max(1, bounds.height * 0.65))
            backdrop.alphaValue = 1 - progress * 0.85
            chrome.alphaValue = 1 - progress
        }

        private func finishDrag(cancelled: Bool) {
            guard acceptsInteraction else {
                resetDrag()
                return
            }
            let axis = dragAxis
            let distance = translation
            let speed = velocity
            resetDrag()
            guard axis != .undecided, axis != .pan else { return }
            if !cancelled, activePage?.isAtFit == true {
                if axis == .horizontal,
                    abs(distance.x) > min(180, viewport.bounds.width * 0.22)
                        || (abs(distance.x) > 35 && abs(speed.x) > 650 && distance.x * speed.x > 0)
                {
                    let direction = distance.x < 0 ? 1 : -1
                    if gallery.items.indices.contains(selectedIndex + direction) {
                        changePage(by: direction)
                        return
                    }
                }
                if axis == .vertical,
                    distance.y > min(180, viewport.bounds.height * 0.22)
                        || (distance.y > 45 && speed.y > 750)
                {
                    dismiss(downward: true)
                    return
                }
            }
            settle(offset: .zero) {}
        }

        private func changePage(by direction: Int) {
            guard acceptsInteraction, !isMagnifying, activePage?.isAtFit == true,
                gallery.items.indices.contains(selectedIndex + direction)
            else { return }
            resetDrag()
            window?.makeFirstResponder(self)
            settle(offset: CGPoint(x: -CGFloat(direction) * pageStride, y: 0)) { [weak self] in
                guard let self else { return }
                self.selectedIndex += direction
                self.displayOffset = .zero
                self.refreshPages()
                NSAccessibility.post(element: self.countLabel, notification: .valueChanged)
            }
        }

        private func settle(offset: CGPoint, completion: @escaping @MainActor () -> Void) {
            isTransitioning = true
            animationGeneration += 1
            let generation = animationGeneration
            displayOffset = offset
            updateControls()
            let finish = { [weak self] in
                guard let self, !self.isInvalidated, !self.isDismissing,
                    self.animationGeneration == generation
                else { return }
                self.isTransitioning = false
                completion()
                self.updateControls()
            }
            if reduceMotion {
                placePages(animated: false)
                backdrop.alphaValue = 1
                chrome.alphaValue = 1
                finish()
            } else {
                NSAnimationContext.runAnimationGroup(
                    { animation in
                        animation.duration = 0.2
                        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.placePages(animated: true)
                        self.backdrop.animator().alphaValue = 1
                        self.chrome.animator().alphaValue = 1
                    }, completionHandler: { MainActor.assumeIsolated { finish() } })
            }
        }

        private func dismiss(downward: Bool) {
            guard !isDismissing, !isInvalidated else { return }
            isDismissing = true
            animationGeneration += 1
            resetDrag()
            for page in pages.values { page.setActive(false, reduceMotion: reduceMotion) }
            updateControls()
            let finish = { [weak self] in
                guard let self, !self.isInvalidated, !self.didDismiss else { return }
                self.didDismiss = true
                self.restoreFocus()
                self.onDismiss()
            }
            if reduceMotion {
                finish()
            } else {
                if downward {
                    displayOffset.y = max(bounds.height, displayOffset.y + bounds.height * 0.35)
                }
                NSAnimationContext.runAnimationGroup(
                    { animation in
                        animation.duration = 0.18
                        animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
                        self.placePages(animated: true)
                        self.animator().alphaValue = 0
                    }, completionHandler: { MainActor.assumeIsolated { finish() } })
            }
        }
    }

    @MainActor
    private final class MessageImageDetailMacPage: NSView {
        let scrollView = NSScrollView()
        let retryButton = NSButton(title: AppLanguage.localized("Retry"), target: nil, action: nil)
        var onZoomChanged: (() -> Void)?
        var onRetry: (() -> Void)?

        private let item: MessageImageItem
        private let mediaContext: AppMediaContext?
        private let loader = ImageDetailImageLoader()
        private let imageDocument = MessageImageDetailMacDocument()
        private let progress = NSProgressIndicator()
        private let statusLabel = NSTextField(labelWithString: "")
        private var subscription: AnyCancellable?
        private var magnificationObservation: NSKeyValueObservation?
        private var displayedImage: NSImage?
        private var isActive = false
        private var reduceMotion = false
        private var lastViewportSize = CGSize.zero
        private var lastImageSize = CGSize.zero

        var isAtFit: Bool { scrollView.magnification <= 1.01 }
        var hasImage: Bool { displayedImage != nil }
        override var isFlipped: Bool { true }

        init(item: MessageImageItem, mediaContext: AppMediaContext?) {
            self.item = item
            self.mediaContext = mediaContext
            super.init(frame: .zero)
            setAccessibilityElement(false)
            wantsLayer = true
            layer?.masksToBounds = true
            scrollView.contentView = MessageImageDetailMacClipView()
            scrollView.drawsBackground = false
            scrollView.contentView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            scrollView.horizontalScrollElasticity = .none
            scrollView.verticalScrollElasticity = .none
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.allowsMagnification = true
            scrollView.minMagnification = 1
            scrollView.maxMagnification = 8
            scrollView.documentView = imageDocument
            addSubview(scrollView)
            imageDocument.setAccessibilityLabel(item.fileName)

            progress.style = .spinning
            progress.isDisplayedWhenStopped = false
            progress.setAccessibilityLabel(AppLanguage.localized("Loading image"))
            addSubview(progress)
            statusLabel.textColor = .white
            statusLabel.font = .systemFont(ofSize: 14)
            statusLabel.alignment = .center
            addSubview(statusLabel)
            retryButton.bezelStyle = .rounded
            retryButton.target = self
            retryButton.action = #selector(retry)
            retryButton.setAccessibilityLabel(AppLanguage.localized("Retry loading image"))
            addSubview(retryButton)
            magnificationObservation = scrollView.observe(\.magnification, options: [.new]) {
                [weak self] _, _ in
                MainActor.assumeIsolated { self?.onZoomChanged?() }
            }
            subscription = Publishers.CombineLatest3(
                loader.$image, loader.$isLoading, loader.$failed
            )
            .sink { [weak self] value in
                self?.render(image: value.0, isLoading: value.1, failed: value.2)
            }
            loader.load(item, mediaContext: mediaContext)
        }

        required init?(coder: NSCoder) { nil }

        func cancel() {
            subscription = nil
            magnificationObservation = nil
            loader.cancel()
            imageDocument.clear()
            displayedImage = nil
            progress.stopAnimation(nil)
        }

        func setActive(_ active: Bool, reduceMotion: Bool) {
            isActive = active
            self.reduceMotion = reduceMotion
            imageDocument.setAnimating(active && !reduceMotion)
        }

        @objc private func retry() {
            onRetry?()
            loader.load(item, mediaContext: mediaContext)
        }

        private func render(image: NSImage?, isLoading: Bool, failed: Bool) {
            if displayedImage !== image {
                displayedImage = image
                imageDocument.setImage(image)
                imageDocument.setAnimating(isActive && !reduceMotion)
                needsLayout = true
            }
            if isLoading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
            progress.isHidden = !isLoading || image != nil
            statusLabel.stringValue =
                failed
                ? AppLanguage.localized("Unable to load image")
                : AppLanguage.localized("Loading image…")
            statusLabel.isHidden = image != nil
            retryButton.isHidden = !failed
            onZoomChanged?()
        }

        override func layout() {
            super.layout()
            let candidate = displayedImage?.size ?? item.pixelSize ?? CGSize(width: 1, height: 1)
            let imageSize =
                candidate.width > 0 && candidate.height > 0
                    && candidate.width.isFinite && candidate.height.isFinite
                ? candidate : CGSize(width: 1, height: 1)
            if bounds.size != lastViewportSize || imageSize != lastImageSize {
                let oldSize = imageDocument.frame.size
                let clip = scrollView.contentView
                let center = CGPoint(
                    x: oldSize.width > 0 ? clip.bounds.midX / oldSize.width : 0.5,
                    y: oldSize.height > 0 ? clip.bounds.midY / oldSize.height : 0.5)
                scrollView.frame = bounds
                let scale = min(
                    max(1, bounds.width) / imageSize.width, max(1, bounds.height) / imageSize.height
                )
                imageDocument.frame = CGRect(
                    origin: .zero,
                    size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
                let proposed = CGPoint(
                    x: center.x * imageDocument.frame.width - clip.bounds.width / 2,
                    y: center.y * imageDocument.frame.height - clip.bounds.height / 2)
                clip.scroll(
                    to: clip.constrainBoundsRect(CGRect(origin: proposed, size: clip.bounds.size))
                        .origin)
                scrollView.reflectScrolledClipView(clip)
                lastViewportSize = bounds.size
                lastImageSize = imageSize
            }
            progress.frame = CGRect(x: bounds.midX - 16, y: bounds.midY - 48, width: 32, height: 32)
            statusLabel.frame = CGRect(
                x: 12, y: bounds.midY, width: max(0, bounds.width - 24), height: 22)
            retryButton.frame = CGRect(
                x: bounds.midX - 48, y: bounds.midY + 34, width: 96, height: 32)
        }

        func toggleZoom(at windowPoint: CGPoint, reduceMotion: Bool) {
            guard hasImage else { return }
            let point = scrollView.contentView.convert(windowPoint, from: nil)
            let target: CGFloat = isAtFit ? 2.5 : 1
            if reduceMotion {
                scrollView.setMagnification(target, centeredAt: point)
            } else {
                NSAnimationContext.runAnimationGroup { animation in
                    animation.duration = 0.2
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.scrollView.animator().setMagnification(target, centeredAt: point)
                }
            }
            onZoomChanged?()
        }

        func pan(by delta: CGPoint) {
            let clip = scrollView.contentView
            let proposed = CGPoint(
                x: clip.bounds.minX - delta.x / scrollView.magnification,
                y: clip.bounds.minY - delta.y / scrollView.magnification)
            clip.scroll(
                to: clip.constrainBoundsRect(CGRect(origin: proposed, size: clip.bounds.size))
                    .origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private final class MessageImageDetailMacContainer: NSView {
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
    }

    private final class MessageImageDetailMacClipView: NSClipView {
        override var isFlipped: Bool { true }

        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            guard let documentView else { return super.constrainBoundsRect(proposedBounds) }
            var result = proposedBounds
            let size = documentView.frame.size
            result.origin.x =
                size.width < result.width
                ? (size.width - result.width) / 2
                : min(max(0, result.minX), size.width - result.width)
            result.origin.y =
                size.height < result.height
                ? (size.height - result.height) / 2
                : min(max(0, result.minY), size.height - result.height)
            return result
        }
    }

    @MainActor
    private final class MessageImageDetailMacDocument: NSView {
        private let imageView = NSImageView()
        private var animatedImageView: AnimatedImageView?

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            imageView.imageScaling = .scaleAxesIndependently
            imageView.animates = false
            imageView.setAccessibilityHidden(true)
            addSubview(imageView)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
        }

        required init?(coder: NSCoder) { nil }

        func setImage(_ image: NSImage?) {
            clear()
            imageView.image = image
            guard let image else { return }
            let frames = image.kf.frameSource?.frameCount ?? image.kf.imageFrameCount ?? 1
            if frames > 1 {
                let animated = AnimatedImageView(frame: bounds)
                animated.autoPlayAnimatedImage = false
                animated.needsPrescaling = false
                animated.imageScaling = .scaleAxesIndependently
                animated.image = image
                animated.setAccessibilityHidden(true)
                addSubview(animated)
                animatedImageView = animated
            }
        }

        func setAnimating(_ enabled: Bool) {
            imageView.animates = enabled && animatedImageView == nil
            animatedImageView?.isHidden = !enabled
            if enabled {
                animatedImageView?.startAnimating()
            } else {
                animatedImageView?.stopAnimating()
            }
        }

        func clear() {
            imageView.animates = false
            imageView.image = nil
            animatedImageView?.stopAnimating()
            animatedImageView?.image = nil
            animatedImageView?.removeFromSuperview()
            animatedImageView = nil
        }

        override func layout() {
            super.layout()
            imageView.frame = bounds
            animatedImageView?.frame = bounds
        }
    }
#endif
