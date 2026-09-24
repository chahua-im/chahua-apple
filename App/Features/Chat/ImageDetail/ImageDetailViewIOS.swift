#if os(iOS)
    import Combine
    import Kingfisher
    import SwiftUI
    import UIKit

    struct ImageDetailPlatformView: UIViewControllerRepresentable {
        let gallery: MessageImageGallery
        let mediaContext: AppMediaContext?
        let onDismiss: () -> Void

        func makeUIViewController(context: Context) -> ImageDetailViewControllerIOS {
            ImageDetailViewControllerIOS(
                gallery: gallery, mediaContext: mediaContext, onDismiss: onDismiss)
        }

        func updateUIViewController(_ controller: ImageDetailViewControllerIOS, context: Context) {
            controller.onDismiss = onDismiss
        }

        static func dismantleUIViewController(
            _ controller: ImageDetailViewControllerIOS, coordinator: ()
        ) {
            controller.tearDown()
        }
    }

    @MainActor
    final class ImageDetailViewControllerIOS: UIViewController, UIScrollViewDelegate,
        UIGestureRecognizerDelegate
    {
        private let gallery: MessageImageGallery
        private let mediaContext: AppMediaContext?
        var onDismiss: () -> Void

        private let backdrop = UIView()
        private let pager = ImageDetailPagerIOS()
        private let chrome = ImageDetailChromeIOS()
        private let closeButton = UIButton(type: .system)
        private let countLabel = UILabel()
        private let previousButton = UIButton(type: .system)
        private let nextButton = UIButton(type: .system)
        private lazy var dismissPan = UIPanGestureRecognizer(
            target: self, action: #selector(dragToDismiss(_:)))
        private var pages: [Int: ImageDetailPageIOS] = [:]
        private var selectedIndex: Int
        private var viewportSize = CGSize.zero
        private var appeared = false
        private var isVisible = false
        private var applicationIsActive = true
        private var isPaging = false
        private var isTransitioning = true
        private var isDraggingToDismiss = false
        private var isChangingViewport = false
        private var dismissalStarted = false
        private var dismissalDelivered = false
        private var isTornDown = false

        private var canInteract: Bool {
            isVisible && applicationIsActive && !isPaging && !isTransitioning
                && !isDraggingToDismiss
                && !isChangingViewport && !dismissalStarted && !isTornDown
        }

        init(
            gallery: MessageImageGallery, mediaContext: AppMediaContext?,
            onDismiss: @escaping () -> Void
        ) {
            self.gallery = gallery
            self.mediaContext = mediaContext
            self.onDismiss = onDismiss
            selectedIndex = gallery.selectedIndex
            super.init(nibName: nil, bundle: nil)
            modalPresentationCapturesStatusBarAppearance = true
        }

        required init?(coder: NSCoder) { nil }

        override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
        override var prefersHomeIndicatorAutoHidden: Bool { true }

        override func loadView() {
            let root = ImageDetailRootViewIOS()
            root.onEscape = { [weak self] in self?.requestClose() ?? false }
            root.onScroll = { [weak self] in self?.accessibilityPage($0) ?? false }
            root.backgroundColor = .clear
            root.accessibilityViewIsModal = true
            view = root
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            backdrop.backgroundColor = .black
            backdrop.isUserInteractionEnabled = false
            backdrop.alpha = 0
            view.addSubview(backdrop)

            pager.delegate = self
            pager.accessibilityIdentifier = "image-detail-viewport"
            pager.backgroundColor = .clear
            pager.isPagingEnabled = true
            pager.bounces = false
            pager.showsHorizontalScrollIndicator = false
            pager.showsVerticalScrollIndicator = false
            pager.contentInsetAdjustmentBehavior = .never
            pager.panGestureRecognizer.maximumNumberOfTouches = 1
            pager.canBeginPaging = { [weak self] in
                guard let self else { return false }
                return self.canInteract && self.pages[self.selectedIndex]?.isAtFit == true
            }
            pager.onAccessibilityScroll = { [weak self] in self?.accessibilityPage($0) ?? false }
            pager.alpha = 0
            view.addSubview(pager)

            chrome.alpha = 0
            view.addSubview(chrome)
            configureButton(
                closeButton, symbol: "xmark", label: AppLanguage.localized("Close image"),
                action: #selector(closeTapped))
            configureButton(
                previousButton, symbol: "chevron.left",
                label: AppLanguage.localized("Previous image"),
                action: #selector(previousTapped))
            configureButton(
                nextButton, symbol: "chevron.right", label: AppLanguage.localized("Next image"),
                action: #selector(nextTapped))
            countLabel.textColor = .white
            countLabel.accessibilityIdentifier = "image-detail-position"
            countLabel.font = .preferredFont(forTextStyle: .subheadline)
            countLabel.adjustsFontForContentSizeCategory = true
            countLabel.textAlignment = .center
            countLabel.adjustsFontSizeToFitWidth = true
            countLabel.minimumScaleFactor = 0.75
            chrome.addSubview(countLabel)

            dismissPan.delegate = self
            dismissPan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(dismissPan)
            NotificationCenter.default.addObserver(
                self, selector: #selector(accessibilityChanged),
                name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(accessibilityChanged),
                name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationResignedActive),
                name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationBecameActive),
                name: UIApplication.didBecomeActiveNotification, object: nil)
            updatePageWindow()
            updateChrome()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !isTornDown else { return }
            isVisible = true
            updatePageStates()
            guard !appeared else { return }
            appeared = true
            let show = {
                self.backdrop.alpha = 1
                self.pager.alpha = 1
                self.chrome.alpha = 1
            }
            let finish: (Bool) -> Void = { [weak self] _ in
                guard let self, !self.dismissalStarted, !self.isTornDown else { return }
                self.isTransitioning = false
                self.updatePageStates()
                UIAccessibility.post(notification: .screenChanged, argument: self.closeButton)
            }
            if UIAccessibility.isReduceMotionEnabled {
                show()
                finish(true)
            } else {
                UIView.animate(
                    withDuration: 0.2, delay: 0, options: [.curveEaseOut], animations: show,
                    completion: finish)
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isVisible = false
            updatePageStates()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let size = view.bounds.size
            backdrop.frame = view.bounds
            chrome.frame = view.bounds
            let resized = viewportSize != size
            if resized {
                viewportSize = size
                pager.bounds.size = size
                pager.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                pager.contentSize = CGSize(
                    width: size.width * CGFloat(gallery.items.count), height: size.height)
                pager.setContentOffset(
                    CGPoint(x: CGFloat(selectedIndex) * size.width, y: 0), animated: false)
                isPaging = false
            }
            for (index, page) in pages {
                page.frame = CGRect(
                    x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
                if resized { page.layoutIfNeeded() }
            }
            let safe = view.safeAreaInsets
            let top = safe.top + 8
            let edge = max(12, safe.right + 8)
            closeButton.frame = CGRect(x: size.width - edge - 44, y: top, width: 44, height: 44)
            countLabel.frame = CGRect(
                x: 64 + safe.left, y: top, width: max(0, size.width - 128 - safe.left - safe.right),
                height: 44)
            previousButton.frame = CGRect(
                x: size.width / 2 - 64, y: size.height - safe.bottom - 56, width: 48, height: 44)
            nextButton.frame = CGRect(
                x: size.width / 2 + 16, y: size.height - safe.bottom - 56, width: 48, height: 44)
            updatePageStates()
        }

        override func viewWillTransition(
            to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator
        ) {
            super.viewWillTransition(to: size, with: coordinator)
            guard !dismissalStarted else { return }
            isChangingViewport = true
            dismissPan.isEnabled = false
            isDraggingToDismiss = false
            // UIKit owns the layer's rotation animations; only unwind our drag translation.
            if pager.transform != .identity { pager.transform = .identity }
            backdrop.alpha = 1
            chrome.alpha = 1
            updatePageStates()
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self, !self.isTornDown else { return }
                self.isChangingViewport = false
                self.dismissPan.isEnabled = true
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
                self.updatePageStates()
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            isVisible = false
            NotificationCenter.default.removeObserver(self)
            guard isViewLoaded else { return }
            view.layer.removeAllAnimations()
            backdrop.layer.removeAllAnimations()
            pager.layer.removeAllAnimations()
            chrome.layer.removeAllAnimations()
            pager.delegate = nil
            pager.canBeginPaging = nil
            pager.onAccessibilityScroll = nil
            dismissPan.isEnabled = false
            for page in pages.values {
                page.tearDown()
                page.removeFromSuperview()
            }
            pages.removeAll()
        }

        private func configureButton(
            _ button: UIButton, symbol: String, label: String, action: Selector
        ) {
            var configuration = UIButton.Configuration.filled()
            configuration.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = UIColor(white: 0.16, alpha: 0.85)
            configuration.cornerStyle = .capsule
            button.configuration = configuration
            button.accessibilityLabel = label
            button.addTarget(self, action: action, for: .touchUpInside)
            chrome.addSubview(button)
        }

        private func updatePageWindow() {
            let lower = max(0, selectedIndex - 1)
            let upper = min(gallery.items.count - 1, selectedIndex + 1)
            for index in Array(pages.keys) where index < lower || index > upper {
                let page = pages.removeValue(forKey: index)
                page?.tearDown()
                page?.removeFromSuperview()
            }
            for index in lower...upper where pages[index] == nil {
                let page = ImageDetailPageIOS(
                    item: gallery.items[index], mediaContext: mediaContext)
                page.onZoomChanged = { [weak self] in self?.updatePageStates() }
                page.mayInteract = { [weak self] in
                    guard let self else { return false }
                    return self.canInteract && self.selectedIndex == index
                }
                page.frame = CGRect(
                    x: CGFloat(index) * viewportSize.width, y: 0, width: viewportSize.width,
                    height: viewportSize.height)
                pager.addSubview(page)
                pages[index] = page
            }
            updatePageStates()
        }

        private func updatePageStates() {
            guard isViewLoaded, !isTornDown else { return }
            let currentIsFit = pages[selectedIndex]?.isAtFit ?? true
            pager.isScrollEnabled =
                canInteract && currentIsFit || isPaging && !isChangingViewport && !dismissalStarted
            for (index, page) in pages {
                let intersectsViewport =
                    page.frame.intersects(pager.bounds) && viewportSize.width > 0
                let visible =
                    isVisible && applicationIsActive && !dismissalStarted && intersectsViewport
                page.setPresentation(
                    visible: visible,
                    interactive: canInteract && index == selectedIndex,
                    animating: visible && canInteract && index == selectedIndex
                        && !UIAccessibility.isReduceMotionEnabled
                )
                page.accessibilityElementsHidden = index != selectedIndex
            }
            closeButton.isEnabled = canInteract
            previousButton.isEnabled = canInteract && currentIsFit && selectedIndex > 0
            nextButton.isEnabled =
                canInteract && currentIsFit && selectedIndex + 1 < gallery.items.count
        }

        private func updateChrome() {
            countLabel.text = AppLanguage.localized(
                "\(selectedIndex + 1) of \(gallery.items.count)")
            countLabel.accessibilityLabel = AppLanguage.localized("Image")
            countLabel.accessibilityValue = countLabel.text
            let showsPagingButtons = UIAccessibility.isVoiceOverRunning && gallery.items.count > 1
            previousButton.isHidden = !showsPagingButtons
            nextButton.isHidden = !showsPagingButtons
            updatePageStates()
        }

        @objc private func accessibilityChanged() { updateChrome() }
        @objc private func applicationResignedActive() {
            applicationIsActive = false
            updatePageStates()
        }
        @objc private func applicationBecameActive() {
            applicationIsActive = true
            updatePageStates()
        }
        @objc private func closeTapped() { _ = requestClose() }
        @objc private func previousTapped() { _ = goToPage(selectedIndex - 1) }
        @objc private func nextTapped() { _ = goToPage(selectedIndex + 1) }

        private func accessibilityPage(_ direction: UIAccessibilityScrollDirection) -> Bool {
            switch direction {
            case .left: return goToPage(selectedIndex + 1)
            case .right: return goToPage(selectedIndex - 1)
            default: return false
            }
        }

        @discardableResult
        private func requestClose() -> Bool {
            guard canInteract else { return false }
            dismissGallery(downward: false)
            return true
        }

        @discardableResult
        private func goToPage(_ index: Int) -> Bool {
            guard canInteract, pages[selectedIndex]?.isAtFit == true,
                gallery.items.indices.contains(index), index != selectedIndex
            else { return false }
            isPaging = true
            updatePageStates()
            pager.setContentOffset(
                CGPoint(x: CGFloat(index) * viewportSize.width, y: 0),
                animated: !UIAccessibility.isReduceMotionEnabled)
            if UIAccessibility.isReduceMotionEnabled { finishPaging() }
            return true
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isPaging = true
            updatePageStates()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if isPaging { updatePageStates() }
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            guard viewportSize.width > 0 else { return }
            let proposed = Int((targetContentOffset.pointee.x / viewportSize.width).rounded())
            let index = min(
                min(gallery.items.count - 1, selectedIndex + 1),
                max(max(0, selectedIndex - 1), proposed))
            targetContentOffset.pointee = CGPoint(x: CGFloat(index) * viewportSize.width, y: 0)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishPaging() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishPaging() }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finishPaging() }

        private func finishPaging() {
            guard !isTornDown, viewportSize.width > 0 else { return }
            let previousIndex = selectedIndex
            selectedIndex = min(
                gallery.items.count - 1,
                max(0, Int((pager.contentOffset.x / viewportSize.width).rounded())))
            isPaging = false
            updatePageWindow()
            updateChrome()
            if selectedIndex != previousIndex {
                UIAccessibility.post(notification: .pageScrolled, argument: countLabel.text)
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dismissPan else { return true }
            guard canInteract, pages[selectedIndex]?.isAtFit == true,
                !pager.isDragging, !pager.isDecelerating
            else { return false }
            let velocity = dismissPan.velocity(in: view)
            return velocity.y > 0 && velocity.y > abs(velocity.x) * 1.15
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            var touchedView = touch.view
            while let current = touchedView {
                if current is UIControl { return false }
                touchedView = current.superview
            }
            return true
        }

        @objc private func dragToDismiss(_ gesture: UIPanGestureRecognizer) {
            guard !isChangingViewport, !dismissalStarted, !isTornDown else { return }
            let translation = gesture.translation(in: view)
            switch gesture.state {
            case .began:
                isDraggingToDismiss = true
                updatePageStates()
                applyDismissalTranslation(translation)
            case .changed:
                applyDismissalTranslation(translation)
            case .ended:
                let distance = max(0, translation.y)
                let velocity = gesture.velocity(in: view)
                if distance > min(180, view.bounds.height * 0.22)
                    || distance > 44 && velocity.y > 850 && velocity.y > abs(velocity.x)
                {
                    dismissGallery(downward: true)
                } else {
                    cancelInteractiveDismissal()
                }
            case .cancelled, .failed:
                if isDraggingToDismiss { cancelInteractiveDismissal() }
            default: break
            }
        }

        private func applyDismissalTranslation(_ translation: CGPoint) {
            let distance = max(0, translation.y)
            let progress = min(1, distance / max(1, view.bounds.height * 0.65))
            if !UIAccessibility.isReduceMotionEnabled {
                pager.transform = CGAffineTransform(translationX: translation.x * 0.2, y: distance)
            }
            backdrop.alpha = 1 - progress
            chrome.alpha = 1 - min(1, progress * 2)
        }

        private func cancelInteractiveDismissal() {
            isTransitioning = true
            isDraggingToDismiss = false
            let restore = {
                self.pager.transform = .identity
                self.backdrop.alpha = 1
                self.chrome.alpha = 1
            }
            let finish: (Bool) -> Void = { [weak self] _ in
                guard let self, !self.dismissalStarted, !self.isTornDown else { return }
                self.isTransitioning = false
                self.updatePageStates()
            }
            if UIAccessibility.isReduceMotionEnabled {
                restore()
                finish(true)
            } else {
                UIView.animate(
                    withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9,
                    initialSpringVelocity: 0, options: [.beginFromCurrentState, .curveEaseOut],
                    animations: restore, completion: finish)
            }
        }

        private func dismissGallery(downward: Bool) {
            guard !dismissalStarted, !isTornDown else { return }
            dismissalStarted = true
            isTransitioning = true
            isDraggingToDismiss = false
            updatePageStates()
            let hide = {
                self.backdrop.alpha = 0
                self.chrome.alpha = 0
                self.pager.alpha = 0
                if downward {
                    self.pager.transform = CGAffineTransform(
                        translationX: self.pager.transform.tx, y: self.view.bounds.height)
                }
            }
            let finish: (Bool) -> Void = { [weak self] _ in
                guard let self, !self.dismissalDelivered, !self.isTornDown else { return }
                self.dismissalDelivered = true
                self.tearDown()
                self.onDismiss()
            }
            if UIAccessibility.isReduceMotionEnabled {
                hide()
                finish(true)
            } else {
                UIView.animate(
                    withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut],
                    animations: hide, completion: finish)
            }
        }
    }

    @MainActor
    private final class ImageDetailRootViewIOS: UIView {
        var onEscape: (() -> Bool)?
        var onScroll: ((UIAccessibilityScrollDirection) -> Bool)?

        override func accessibilityPerformEscape() -> Bool { onEscape?() ?? false }
        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            onScroll?(direction) ?? false
        }
    }

    @MainActor
    private final class ImageDetailChromeIOS: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }

    @MainActor
    private final class ImageDetailPagerIOS: UIScrollView {
        var canBeginPaging: (() -> Bool)?
        var onAccessibilityScroll: ((UIAccessibilityScrollDirection) -> Bool)?

        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            onAccessibilityScroll?(direction) ?? false
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool
        {
            if gestureRecognizer === panGestureRecognizer {
                let velocity = panGestureRecognizer.velocity(in: self)
                guard canBeginPaging?() == true, abs(velocity.x) > abs(velocity.y) else {
                    return false
                }
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
    }

    @MainActor
    private final class ImageDetailZoomScrollViewIOS: UIScrollView {
        var mayInteract: (() -> Bool)?

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool
        {
            if gestureRecognizer === panGestureRecognizer {
                guard mayInteract?() == true,
                    zoomScale > minimumZoomScale + 0.01 || pinchGestureRecognizer?.state == .began
                        || pinchGestureRecognizer?.state == .changed
                else { return false }
            } else if gestureRecognizer === pinchGestureRecognizer, mayInteract?() != true {
                return false
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
    }

    @MainActor
    private final class ImageDetailPageIOS: UIView, UIScrollViewDelegate {
        private let item: MessageImageItem
        private let mediaContext: AppMediaContext?
        private let loader = ImageDetailImageLoader()
        private let scrollView = ImageDetailZoomScrollViewIOS()
        private let imageCanvas = UIView()
        private let stillImage = UIImageView()
        private var animatedImage: AnimatedImageView?
        private let spinner = UIActivityIndicatorView(style: .large)
        private let errorLabel = UILabel()
        private let retryButton = UIButton(type: .system)
        private lazy var doubleTap = UITapGestureRecognizer(
            target: self, action: #selector(doubleTapped(_:)))
        private var observation: AnyCancellable?
        private var installedImage: UIImage?
        private var laidOutSize = CGSize.zero
        private var visible = false
        private var interactive = false
        private var animationsAllowed = false
        private var requested = false
        private var failed = false
        private var loading = false
        private var layingOutImage = false
        private var zoomAnimationRunning = false
        private var tornDown = false
        var onZoomChanged: (() -> Void)?
        var mayInteract: (() -> Bool)?

        var isAtFit: Bool {
            !zoomAnimationRunning && !scrollView.isZooming && !scrollView.isZoomBouncing
                && scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
        }

        init(item: MessageImageItem, mediaContext: AppMediaContext?) {
            self.item = item
            self.mediaContext = mediaContext
            super.init(frame: .zero)
            clipsToBounds = true
            scrollView.delegate = self
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 5
            scrollView.bouncesZoom = true
            scrollView.decelerationRate = .fast
            scrollView.mayInteract = { [weak self] in
                self?.interactive == true && self?.installedImage != nil
            }
            addSubview(scrollView)
            imageCanvas.isAccessibilityElement = true
            imageCanvas.accessibilityTraits = .image
            imageCanvas.accessibilityLabel =
                item.fileName.isEmpty ? AppLanguage.localized("Image") : item.fileName
            imageCanvas.accessibilityHint = AppLanguage.localized("Pinch or double-tap to zoom.")
            scrollView.addSubview(imageCanvas)
            stillImage.contentMode = .scaleToFill
            imageCanvas.addSubview(stillImage)
            doubleTap.numberOfTapsRequired = 2
            scrollView.addGestureRecognizer(doubleTap)
            spinner.color = .white
            spinner.hidesWhenStopped = true
            addSubview(spinner)
            errorLabel.text = AppLanguage.localized("Unable to load image")
            errorLabel.font = .preferredFont(forTextStyle: .body)
            errorLabel.adjustsFontForContentSizeCategory = true
            errorLabel.textColor = .white
            errorLabel.textAlignment = .center
            errorLabel.numberOfLines = 0
            errorLabel.isHidden = true
            addSubview(errorLabel)
            var retryConfiguration = UIButton.Configuration.filled()
            retryConfiguration.title = AppLanguage.localized("Retry")
            retryConfiguration.baseBackgroundColor = .darkGray
            retryConfiguration.baseForegroundColor = .white
            retryConfiguration.cornerStyle = .capsule
            retryButton.configuration = retryConfiguration
            retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
            retryButton.isHidden = true
            addSubview(retryButton)
            observation = Publishers.CombineLatest3(
                loader.$image, loader.$isLoading, loader.$failed
            )
            .sink { [weak self] image, loading, failed in
                self?.render(image: image, loading: loading, failed: failed)
            }
        }

        required init?(coder: NSCoder) { nil }

        func setPresentation(visible: Bool, interactive: Bool, animating: Bool) {
            guard !tornDown else { return }
            self.visible = visible
            self.interactive = interactive
            animationsAllowed = animating
            doubleTap.isEnabled = interactive && installedImage != nil && !zoomAnimationRunning
            retryButton.isEnabled = interactive
            // Do not toggle an active pinch recognizer while its zoom callback updates the pager.
            if scrollView.pinchGestureRecognizer?.state != .began
                && scrollView.pinchGestureRecognizer?.state != .changed
            {
                scrollView.pinchGestureRecognizer?.isEnabled = interactive && installedImage != nil
            }
            if visible, !requested {
                requested = true
                loader.load(item, mediaContext: mediaContext)
            } else if !visible, loading {
                requested = false
                loader.cancel()
            }
            updateLoadingChrome()
            updateAnimation()
        }

        func tearDown() {
            guard !tornDown else { return }
            tornDown = true
            observation?.cancel()
            observation = nil
            loader.cancel()
            scrollView.delegate = nil
            scrollView.mayInteract = nil
            scrollView.layer.removeAllAnimations()
            animatedImage?.stopAnimating()
            animatedImage?.image = nil
            stillImage.stopAnimating()
            stillImage.animationImages = nil
            stillImage.image = nil
            installedImage = nil
            spinner.stopAnimating()
            onZoomChanged = nil
            mayInteract = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scrollView.frame = bounds
            if laidOutSize != bounds.size {
                laidOutSize = bounds.size
                layoutImageAtFit()
            }
            spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
            let labelWidth = max(0, min(360, bounds.width - 48))
            let labelSize = errorLabel.sizeThatFits(
                CGSize(width: labelWidth, height: .greatestFiniteMagnitude))
            errorLabel.frame = CGRect(
                x: (bounds.width - labelWidth) / 2, y: bounds.midY - labelSize.height - 12,
                width: labelWidth, height: labelSize.height)
            retryButton.frame = CGRect(
                x: bounds.midX - 60, y: bounds.midY + 8, width: 120, height: 48)
        }

        private func render(image: UIImage?, loading: Bool, failed: Bool) {
            guard !tornDown else { return }
            self.loading = loading
            self.failed = failed
            if let image, installedImage !== image {
                installedImage = image
                stillImage.image = image.images?.first ?? image
                imageCanvas.isHidden = false
                layoutImageAtFit()
                doubleTap.isEnabled = interactive && !zoomAnimationRunning
                scrollView.pinchGestureRecognizer?.isEnabled = interactive
            }
            updateLoadingChrome()
            updateAnimation()
        }

        private func updateLoadingChrome() {
            let showError = failed && installedImage == nil
            errorLabel.isHidden = !showError
            retryButton.isHidden = !showError
            imageCanvas.isHidden = installedImage == nil
            if visible && installedImage == nil && !failed && loading {
                spinner.startAnimating()
            } else {
                spinner.stopAnimating()
            }
        }

        private func updateAnimation() {
            guard let image = installedImage, animationsAllowed,
                (image.kf.frameSource?.frameCount ?? image.kf.imageFrameCount ?? 1) > 1
            else {
                animatedImage?.stopAnimating()
                animatedImage?.image = nil
                animatedImage?.isHidden = true
                stillImage.stopAnimating()
                stillImage.animationImages = nil
                stillImage.isHidden = false
                return
            }
            guard image.kf.frameSource != nil else {
                if let frames = image.images, !stillImage.isAnimating {
                    stillImage.animationImages = frames
                    stillImage.animationDuration = image.duration
                    stillImage.startAnimating()
                }
                return
            }
            let animated: AnimatedImageView
            if let animatedImage {
                animated = animatedImage
            } else {
                animated = AnimatedImageView(frame: imageCanvas.bounds)
                animated.autoPlayAnimatedImage = false
                animated.needsPrescaling = false
                animated.contentMode = .scaleToFill
                imageCanvas.addSubview(animated)
                animatedImage = animated
            }
            if animated.image !== image { animated.image = image }
            animated.frame = imageCanvas.bounds
            animated.isHidden = false
            stillImage.isHidden = true
            animated.startAnimating()
        }

        private func layoutImageAtFit() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            layingOutImage = true
            zoomAnimationRunning = false
            scrollView.setZoomScale(1, animated: false)
            scrollView.contentInset = .zero
            let imageSize = installedImage?.size ?? item.pixelSize ?? bounds.size
            let scale = min(
                bounds.width / max(1, imageSize.width), bounds.height / max(1, imageSize.height))
            let fitted = CGSize(
                width: max(1, imageSize.width * scale), height: max(1, imageSize.height * scale))
            imageCanvas.frame = CGRect(origin: .zero, size: fitted)
            stillImage.frame = imageCanvas.bounds
            animatedImage?.frame = imageCanvas.bounds
            scrollView.contentSize = fitted
            scrollView.contentOffset = .zero
            centerImage()
            layingOutImage = false
            onZoomChanged?()
        }

        private func centerImage() {
            let insetX = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let insetY = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            imageCanvas.center = CGPoint(
                x: scrollView.contentSize.width / 2 + insetX,
                y: scrollView.contentSize.height / 2 + insetY)
            scrollView.bounces = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
        }

        @objc private func retry() {
            guard mayInteract?() == true, !loading else { return }
            requested = true
            loader.load(item, mediaContext: mediaContext)
        }

        @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard mayInteract?() == true, installedImage != nil, !zoomAnimationRunning else {
                return
            }
            let zoomIn = scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
            zoomAnimationRunning = !UIAccessibility.isReduceMotionEnabled
            onZoomChanged?()
            if zoomIn {
                let targetScale = min(3, scrollView.maximumZoomScale)
                let point = gesture.location(in: imageCanvas)
                let width = scrollView.bounds.width / targetScale
                let height = scrollView.bounds.height / targetScale
                let rect = CGRect(
                    x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
                scrollView.zoom(to: rect, animated: zoomAnimationRunning)
            } else {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: zoomAnimationRunning)
            }
            if !zoomAnimationRunning { onZoomChanged?() }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            installedImage == nil ? nil : imageCanvas
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            if !layingOutImage { onZoomChanged?() }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard !layingOutImage else { return }
            centerImage()
            onZoomChanged?()
        }

        func scrollViewDidEndZooming(
            _ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat
        ) {
            zoomAnimationRunning = false
            guard !layingOutImage else { return }
            centerImage()
            onZoomChanged?()
        }
    }
#endif
