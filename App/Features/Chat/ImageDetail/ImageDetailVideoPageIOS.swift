#if os(iOS)
    import AVFoundation
    import AVKit
    import Combine
    import UIKit

    /// A video page in the UIKit media viewer, hosting `AVPlayerViewController`.
    ///
    /// Requirement: native transport controls (play/pause, scrubbing, AirPlay, full screen)
    /// inside the existing UIKit pager, with playback driven by page selection. SwiftUI's
    /// `VideoPlayer` would need a hosting controller per pager page and exposes neither the
    /// full-screen delegate nor control layout, so AVKit's controller is contained directly;
    /// the viewer adds `childViewController` as a child while the page is installed.
    ///
    /// Picture in Picture is disabled: the viewer owns the player's lifetime (paused when the
    /// page is deselected or the app resigns active, released on page-out and dismissal) and
    /// the app has no background audio mode, so a PiP window could not outlive the viewer.
    @MainActor
    final class ImageDetailVideoPageIOS: UIView, ImageDetailPageContentIOS,
        AVPlayerViewControllerDelegate
    {
        private let item: MessageImageItem
        private let videoCache: VideoFileCache?
        private var loadPolicy: MediaLoadPolicy
        private var userInitiated: Bool
        private var policyObservation: AnyCancellable?
        private let playerController = AVPlayerViewController()
        private let errorLabel = UILabel()
        private let retryButton = UIButton(type: .system)
        private let progressView = VideoDownloadProgressView()
        private var downloadTask: Task<Void, Never>?
        private var loadID = UUID()
        private var fileLease: VideoFileLease?
        private var player: AVPlayer?
        private let audioSessionOwner = UUID()
        private var statusObservation: AnyCancellable?
        private var playbackObservation: AnyCancellable?
        private var rateObservation: AnyCancellable?
        private var endObservation: AnyCancellable?
        private var playbackIntent = false
        private var playbackGeneration = 0
        private var loopSeekPending = false
        private let loopButton = UIButton(type: .system)
        private let interactionObserver = ImageDetailVideoInteractionIOS()
        private var fullScreenChromeTask: Task<Void, Never>?
        private var fullScreenChromeHidden = false
        private var fullScreenTouchActive = false
        private var playableCheck: Task<Void, Never>?
        private var visible = false
        private var selected = false
        private var interactive = false
        /// Set when the page becomes the selected page, consumed by the next autoplay, so
        /// returning from the background or a cancelled drag never restarts a paused video.
        private var autoplayPending = false
        private var failed = false
        private var presentingFullScreen = false
        private weak var fullScreenPresentation: UIViewController?
        private var tornDown = false
        private var playbackHandoffGeneration = 0
        var mayInteract: (() -> Bool)?
        var onPlaybackChanged: (() -> Void)?
        var onFullScreenChromeChanged: (() -> Void)?
        /// Nil leaves inline gallery navigation under the viewer's own timer.
        var fullScreenNavigationHidden: Bool? {
            presentingFullScreen ? fullScreenChromeHidden : nil
        }
        private(set) var isLoopEnabled = true

        var isPlaying: Bool {
            playbackIntent && (player?.timeControlStatus == .playing || loopSeekPending)
        }

        static var accessibilityKeepsChromeVisible: Bool {
            UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
                || UIAccessibility.isAssistiveTouchRunning
        }

        var isAtFit: Bool { true }
        var childViewController: UIViewController? { playerController }

        init(item: MessageImageItem, mediaContext: AppMediaContext?, userInitiated: Bool) {
            self.item = item
            videoCache = mediaContext?.videoCache
            loadPolicy = mediaContext?.loadPolicy ?? .cacheOnly
            self.userInitiated = userInitiated
            super.init(frame: .zero)
            clipsToBounds = true
            playerController.delegate = self
            playerController.showsPlaybackControls = true
            playerController.videoGravity = .resizeAspect
            playerController.allowsPictureInPicturePlayback = false
            // Paused-on-background playback would leave a stale lock screen entry.
            playerController.updatesNowPlayingInfoCenter = false
            playerController.view.backgroundColor = .clear
            playerController.view.accessibilityLabel =
                item.fileName.isEmpty ? AppLanguage.localized("Video") : item.fileName
            addSubview(playerController.view)
            configureFullScreenLoopControl()
            interactionObserver.onBegan = { [weak self] point in
                guard let self, self.presentingFullScreen else { return false }
                let safeTop = self.interactionObserver.view?.safeAreaInsets.top ?? 0
                // AVKit's top band contains its native exit; never consume that control.
                let consume = self.fullScreenChromeHidden && point.y > safeTop + 64
                self.fullScreenTouchActive = true
                self.updateFullScreenChrome(reveal: true)
                return consume
            }
            interactionObserver.onEnded = { [weak self] in
                guard let self else { return }
                self.fullScreenTouchActive = false
                self.updateFullScreenChrome()
            }
            playerController.view.addGestureRecognizer(interactionObserver)
            interactionObserver.onKeyboardInteraction = { [weak self] in
                self?.updateFullScreenChrome(reveal: true)
            }
            for name in [
                UIAccessibility.voiceOverStatusDidChangeNotification,
                UIAccessibility.switchControlStatusDidChangeNotification,
                UIAccessibility.assistiveTouchStatusDidChangeNotification,
                UIAccessibility.elementFocusedNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(accessibilityChanged), name: name, object: nil)
            }
            progressView.isHidden = true
            addSubview(progressView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationResignedActive),
                name: UIApplication.willResignActiveNotification, object: nil)

            errorLabel.text = AppLanguage.localized("This video can’t be played")
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
            policyObservation = mediaContext?.loadPolicyChanges.sink { [weak self] policy in
                self?.applyLoadPolicy(policy)
            }
        }

        required init?(coder: NSCoder) { nil }

        func setPresentation(visible: Bool, selected: Bool, interactive: Bool, animating _: Bool) {
            guard !tornDown else { return }
            if selected, !self.selected { autoplayPending = true }
            if !selected || (self.visible && !visible && !presentingFullScreen) {
                autoplayPending = false
            }
            self.visible = visible
            self.selected = selected
            self.interactive = interactive
            retryButton.isEnabled = interactive
            applyPlayback()
        }

        /// AVKit lays its transport bar (scrubber, time) along the bottom of its safe area and
        /// secondary buttons (volume, full screen) along the top, without exposing either
        /// region or a controls-visible state. Paging and drag-to-dismiss therefore never start
        /// in those bands, so scrubbing cannot page or dismiss; the video's middle still does.
        func allowsContainerGesture(at point: CGPoint) -> Bool {
            let controls = playerController.view!
            guard !failed, controls.superview === self else { return true }
            let local = convert(point, to: controls)
            let safe = controls.bounds.inset(by: controls.safeAreaInsets)
            let inTopControls = local.y >= safe.minY - 8 && local.y < safe.minY + 64
            let inBottomControls = local.y > safe.maxY - 96 && local.y <= safe.maxY + 16
            return !inTopControls && !inBottomControls
        }

        func tearDown() {
            guard !tornDown else { return }
            tornDown = true
            stopPlayback()
            fullScreenChromeTask?.cancel()
            fullScreenChromeTask = nil
            playbackHandoffGeneration += 1
            NotificationCenter.default.removeObserver(self)
            policyObservation = nil
            cancelDownload()
            statusObservation?.cancel()
            statusObservation = nil
            playbackObservation = nil
            rateObservation = nil
            endObservation = nil
            playableCheck?.cancel()
            playableCheck = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            playerController.player = nil
            playerController.delegate = nil
            player = nil
            fileLease = nil
            ImageDetailVideoAudioSession.release(owner: audioSessionOwner)
            interactionObserver.onBegan = nil
            interactionObserver.onEnded = nil
            interactionObserver.onKeyboardInteraction = nil
            interactionObserver.view?.removeGestureRecognizer(interactionObserver)
            onPlaybackChanged = nil
            onFullScreenChromeChanged = nil
            mayInteract = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // AVKit's full-screen presentation temporarily reparents its player content.
            if playerController.view.superview === self { playerController.view.frame = bounds }
            progressView.frame = CGRect(
                x: bounds.midX - 32, y: bounds.midY - 32, width: 64, height: 64)
            let labelWidth = max(0, min(360, bounds.width - 48))
            let labelSize = errorLabel.sizeThatFits(
                CGSize(width: labelWidth, height: .greatestFiniteMagnitude))
            errorLabel.frame = CGRect(
                x: (bounds.width - labelWidth) / 2, y: bounds.midY - labelSize.height - 12,
                width: labelWidth, height: labelSize.height)
            retryButton.frame = CGRect(
                x: bounds.midX - 60, y: bounds.midY + 8, width: 120, height: 48)
        }

        private func applyPlayback() {
            playbackHandoffGeneration += 1
            // AVKit temporarily hides the gallery while presenting full screen. Deselection
            // still wins: only the selected item can retain playback in that presentation.
            guard !tornDown else { return }
            guard selected, visible || presentingFullScreen else {
                cancelDownload()
                stopPlayback()
                return
            }
            guard !presentingFullScreen else { return }
            if player == nil, downloadTask == nil, !failed { load() }
            guard autoplayPending, !failed, let player else { return }
            let generation = playbackHandoffGeneration
            // Page selection/appearance can run in SwiftUI's controller update.
            // Audio ownership stops the observed voice player, so hand off the
            // complete autoplay transaction after native layout has returned.
            DispatchQueue.main.async { [weak self, weak player] in
                guard let self, let player, playbackHandoffGeneration == generation,
                    !tornDown, !presentingFullScreen, visible, selected,
                    autoplayPending, !failed, self.player === player,
                    UIApplication.shared.applicationState == .active
                else { return }
                autoplayPending = false
                playbackIntent = true
                ImageDetailVideoAudioSession.activate(owner: audioSessionOwner)
                player.play()
            }
        }

        private func applyLoadPolicy(_ policy: MediaLoadPolicy) {
            let before = loadPolicy.allowsNetwork(isVideo: true, userInitiated: userInitiated)
            loadPolicy = policy
            let after = policy.allowsNetwork(isVideo: true, userInitiated: userInitiated)
            guard before != after, item.url?.isFileURL == false, player == nil else { return }
            cancelDownload()
            if failed { setFailed(false) }
            applyPlayback()
        }

        private func load() {
            guard !tornDown, visible, selected, downloadTask == nil else { return }
            guard let url = item.url else {
                showFailure()
                return
            }
            guard url.isFileURL || videoCache != nil else {
                showFailure(notDownloaded: true)
                return
            }
            let allowsNetwork = loadPolicy.allowsNetwork(
                isVideo: true, userInitiated: userInitiated)
            let previousLease = fileLease
            releasePlayer()
            setFailed(false)
            progressView.update(.indeterminate)
            progressView.isHidden = !allowsNetwork && !url.isFileURL
            let id = UUID()
            loadID = id
            let cache = videoCache
            downloadTask = Task { [weak self] in
                if let previousLease { await cache?.invalidate(previousLease) }
                do {
                    let lease: VideoFileLease
                    if url.isFileURL {
                        lease = VideoFileLease(localURL: url)
                    } else if let cache {
                        lease = try await cache.file(for: url, allowsNetwork: allowsNetwork) {
                            [weak self] progress in
                            guard let self, !self.tornDown, self.loadID == id,
                                self.visible, self.selected
                            else { return }
                            self.progressView.update(progress)
                        }
                    } else {
                        throw VideoFileCache.CacheMiss.notDownloaded
                    }
                    guard !Task.isCancelled, let self, !self.tornDown,
                        self.loadID == id, self.visible, self.selected
                    else { return }
                    self.downloadTask = nil
                    self.fileLease = lease
                    self.installPlayer(url: lease.url)
                    self.applyPlayback()
                } catch {
                    guard !Task.isCancelled, let self, !self.tornDown,
                        self.loadID == id, self.visible, self.selected
                    else { return }
                    self.downloadTask = nil
                    self.showFailure(notDownloaded: error is VideoFileCache.CacheMiss)
                }
            }
        }

        private func installPlayer(url: URL) {
            let asset = AVURLAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            self.player = player
            playerController.player = player
            // Keep the desired rate at natural end while looping. A seek preserves that
            // rate, so its completion never calls play() and cannot undo a native pause.
            player.actionAtItemEnd = isLoopEnabled ? .none : .pause
            // AVKit's own play button may start playback the viewer did not start.
            playbackObservation = player.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak player] _ in
                    guard let self, let player, self.player === player else { return }
                    self.playbackChanged(player)
                }
            rateObservation = player.publisher(for: \.rate)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak player] _ in
                    guard let self, let player, self.player === player else { return }
                    self.playbackChanged(player)
                }
            endObservation = NotificationCenter.default.publisher(
                for: .AVPlayerItemDidPlayToEndTime, object: playerItem
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak player, weak playerItem] _ in
                guard let self, let player, let playerItem,
                    self.player === player, player.currentItem === playerItem
                else { return }
                self.repeatCurrentItem(player, item: playerItem)
            }
            statusObservation = playerItem.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak playerItem] status in
                    guard let self, let playerItem, self.player?.currentItem === playerItem
                    else { return }
                    if status == .failed {
                        self.showFailure()
                    } else if status == .readyToPlay {
                        self.progressView.isHidden = true
                    }
                }
            progressView.update(.indeterminate)
            playableCheck = Task { [weak self, weak playerItem] in
                let playable = (try? await asset.load(.isPlayable)) ?? false
                guard !Task.isCancelled, !playable, let self, let playerItem,
                    self.player?.currentItem === playerItem
                else { return }
                self.showFailure()
            }
        }

        private func cancelDownload() {
            loadID = UUID()
            downloadTask?.cancel()
            downloadTask = nil
            if player == nil { progressView.isHidden = true }
        }

        private func releasePlayer() {
            statusObservation?.cancel()
            statusObservation = nil
            stopPlayback()
            playbackObservation = nil
            rateObservation = nil
            endObservation = nil
            playableCheck?.cancel()
            playableCheck = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            playerController.player = nil
            player = nil
            fileLease = nil
            ImageDetailVideoAudioSession.release(owner: audioSessionOwner)
        }

        @objc private func applicationResignedActive() {
            autoplayPending = false
            cancelDownload()
            stopPlayback()
        }

        private func showFailure(notDownloaded: Bool = false) {
            guard !tornDown, !failed else { return }
            stopPlayback()
            progressView.isHidden = true
            if let fileLease, let videoCache {
                Task { await videoCache.invalidate(fileLease) }
            }
            errorLabel.text = AppLanguage.localized(
                notDownloaded ? "Media not downloaded" : "This video can’t be played")
            retryButton.configuration?.title = AppLanguage.localized(
                notDownloaded ? "Download" : "Retry")
            setNeedsLayout()
            setFailed(true)
        }

        private func setFailed(_ failed: Bool) {
            self.failed = failed
            playerController.view.isHidden = failed
            errorLabel.isHidden = !failed
            retryButton.isHidden = !failed
        }

        @objc private func retry() {
            guard !tornDown, failed, mayInteract?() == true else { return }
            // Discard a failed cached asset before requesting a fresh completed file.
            setFailed(false)
            userInitiated = true
            autoplayPending = selected
            load()
            applyPlayback()
        }

        func makeLoopAction() -> UIAction {
            UIAction(
                title: AppLanguage.localized("Loop"), image: UIImage(systemName: "repeat"),
                state: isLoopEnabled ? .on : .off
            ) { [weak self] _ in
                self?.toggleLoop()
            }
        }

        @objc private func toggleLoop() {
            guard !tornDown else { return }
            isLoopEnabled.toggle()
            if !isLoopEnabled {
                let wasSeeking = loopSeekPending
                cancelPendingLoop()
                // Disabling during the end-of-item seek must not start another iteration.
                if wasSeeking { stopPlayback() }
            }
            player?.actionAtItemEnd = isLoopEnabled ? .none : .pause
            updateLoopButton()
            updateFullScreenChrome(reveal: true)
            onPlaybackChanged?()
        }

        private func playbackChanged(_ player: AVPlayer) {
            guard !tornDown else { return }
            guard UIApplication.shared.applicationState == .active, selected,
                visible || presentingFullScreen
            else {
                stopPlayback()
                return
            }
            playbackIntent = player.rate != 0
            if !playbackIntent {
                cancelPendingLoop()
                ImageDetailVideoAudioSession.release(owner: audioSessionOwner)
            } else {
                ImageDetailVideoAudioSession.activate(owner: audioSessionOwner)
            }
            updateFullScreenChrome()
            onPlaybackChanged?()
        }

        private func repeatCurrentItem(_ player: AVPlayer, item: AVPlayerItem) {
            guard !tornDown, !failed, isLoopEnabled, playbackIntent, player.rate > 0,
                selected, visible || presentingFullScreen,
                UIApplication.shared.applicationState == .active, !loopSeekPending,
                CMTimeCompare(player.currentTime(), item.duration) >= 0
            else { return }
            loopSeekPending = true
            let generation = playbackGeneration
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) {
                [weak self, weak player, weak item] finished in
                Task { @MainActor in
                    guard let self, let player, let item,
                        self.playbackGeneration == generation, self.player === player,
                        player.currentItem === item, self.loopSeekPending
                    else { return }
                    self.loopSeekPending = false
                    // A native scrub can supersede this seek. Leave that newer request's
                    // rate and position alone; never pause or restart it in our completion.
                    guard finished else {
                        self.updateFullScreenChrome()
                        self.onPlaybackChanged?()
                        return
                    }
                    guard !self.tornDown, !self.failed, self.isLoopEnabled,
                        self.playbackIntent, player.rate > 0, self.selected,
                        self.visible || self.presentingFullScreen,
                        UIApplication.shared.applicationState == .active
                    else {
                        self.stopPlayback()
                        return
                    }
                    self.updateFullScreenChrome()
                    self.onPlaybackChanged?()
                }
            }
        }

        private func cancelPendingLoop() {
            playbackGeneration += 1
            guard loopSeekPending else { return }
            loopSeekPending = false
            player?.currentItem?.cancelPendingSeeks()
        }

        private func stopPlayback() {
            playbackHandoffGeneration += 1
            playbackIntent = false
            cancelPendingLoop()
            if let player, player.rate != 0 || player.timeControlStatus != .paused {
                player.pause()
            }
            ImageDetailVideoAudioSession.release(owner: audioSessionOwner)
            updateFullScreenChrome(reveal: true)
            onPlaybackChanged?()
        }

        private func configureFullScreenLoopControl() {
            // iOS has no public custom transport-menu API (AVKit's custom menu items are
            // tvOS-only). Its public content overlay keeps Loop reachable in native full
            // screen, without inspecting AVKit's views or replacing transport controls.
            guard let overlay = playerController.contentOverlayView else { return }
            overlay.isUserInteractionEnabled = true
            loopButton.translatesAutoresizingMaskIntoConstraints = false
            loopButton.accessibilityIdentifier = "image-detail-video-loop"
            loopButton.addTarget(self, action: #selector(toggleLoop), for: .touchUpInside)
            loopButton.isHidden = true
            overlay.addSubview(loopButton)
            // Leave room for AVKit's scrubber and its separate playback-speed row.
            NSLayoutConstraint.activate([
                loopButton.trailingAnchor.constraint(
                    equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -16),
                loopButton.bottomAnchor.constraint(
                    equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -176),
                loopButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
                loopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
            updateLoopButton()
        }

        private func updateLoopButton() {
            var configuration = UIButton.Configuration.filled()
            configuration.title = AppLanguage.localized("Loop")
            configuration.image = UIImage(systemName: "repeat")
            configuration.imagePadding = 6
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = UIColor(
                white: isLoopEnabled ? 0.35 : 0.12, alpha: 0.9)
            configuration.cornerStyle = .capsule
            loopButton.configuration = configuration
            loopButton.isSelected = isLoopEnabled
            loopButton.accessibilityTraits = isLoopEnabled ? [.button, .selected] : [.button]
        }

        private var canHideFullScreenChrome: Bool {
            let inputView = interactionObserver.view ?? playerController.view!
            let focusedView = UIFocusSystem.focusSystem(for: inputView)?.focusedItem as? UIView
            return presentingFullScreen && isPlaying && !fullScreenTouchActive
                && !interactionObserver.keyboardActive
                && focusedView?.isDescendant(of: inputView) != true
                && !Self.accessibilityKeepsChromeVisible && !tornDown
                && UIApplication.shared.applicationState == .active
        }

        private func updateFullScreenChrome(reveal: Bool = false) {
            if reveal || !canHideFullScreenChrome {
                fullScreenChromeTask?.cancel()
                fullScreenChromeTask = nil
                fullScreenChromeHidden = false
            }
            loopButton.isHidden = !presentingFullScreen || fullScreenChromeHidden
            onFullScreenChromeChanged?()
            guard canHideFullScreenChrome, !fullScreenChromeHidden, fullScreenChromeTask == nil
            else { return }
            fullScreenChromeTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.fullScreenChromeTask = nil
                guard self.canHideFullScreenChrome else { return }
                // AVKit's fullscreen controller is itself a public presentation; only an
                // additional presentation above it (for example AirPlay) retains chrome.
                let presented = self.playerController.presentedViewController
                let hasMenu =
                    presented === self.fullScreenPresentation
                    ? presented?.presentedViewController != nil : presented != nil
                guard !hasMenu else {
                    self.updateFullScreenChrome()
                    return
                }
                self.fullScreenChromeHidden = true
                self.loopButton.isHidden = true
                self.onFullScreenChromeChanged?()
            }
        }

        @objc private func accessibilityChanged() {
            updateFullScreenChrome(reveal: true)
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator:
                UIViewControllerTransitionCoordinator
        ) {
            presentingFullScreen = true
            fullScreenPresentation =
                playerViewController.presentedViewController
                ?? coordinator.viewController(forKey: .to)
            // AVKit moves its overlay into the transition's destination. Observe input on
            // that public controller's root, not any private AVKit control/content view.
            fullScreenPresentation?.view.addGestureRecognizer(interactionObserver)
            updateFullScreenChrome(reveal: true)
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, !self.tornDown else { return }
                if context.isCancelled {
                    self.presentingFullScreen = false
                    self.fullScreenPresentation = nil
                    self.playerController.view.addGestureRecognizer(self.interactionObserver)
                    self.updateFullScreenChrome()
                    self.applyPlayback()
                } else {
                    self.fullScreenPresentation =
                        self.playerController.presentedViewController ?? self.fullScreenPresentation
                    self.fullScreenPresentation?.view.addGestureRecognizer(self.interactionObserver)
                    self.updateFullScreenChrome()
                }
            }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator:
                UIViewControllerTransitionCoordinator
        ) {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, !self.tornDown, !context.isCancelled else { return }
                self.presentingFullScreen = false
                self.fullScreenPresentation = nil
                self.playerController.view.addGestureRecognizer(self.interactionObserver)
                self.updateFullScreenChrome()
                self.setNeedsLayout()
                self.applyPlayback()
            }
        }
    }

    /// Observe public input delivery rather than AVKit's private control hierarchy. While
    /// chrome is hidden, consume the reveal gesture so it cannot also press native Pause.
    @MainActor
    final class ImageDetailVideoInteractionIOS: UIGestureRecognizer {
        var onBegan: ((CGPoint) -> Bool)?
        var onEnded: (() -> Void)?
        var onKeyboardInteraction: (() -> Void)?
        private var activePresses: Set<UIPress> = []
        var keyboardActive: Bool { !activePresses.isEmpty }
        private var consuming = false
        private var activeTouches: Set<UITouch> = []

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            allowedPressTypes = [
                UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow,
                .select, .menu, .playPause,
            ].map { NSNumber(value: $0.rawValue) }
        }

        convenience init() { self.init(target: nil, action: nil) }
        required init?(coder: NSCoder) { nil }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            let wasEmpty = activeTouches.isEmpty
            activeTouches.formUnion(touches)
            if wasEmpty {
                consuming = onBegan?(touches.first?.location(in: view) ?? .zero) ?? false
                if consuming { state = .began }
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if consuming { state = .changed }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            activeTouches.subtract(touches)
            guard activeTouches.isEmpty else { return }
            onEnded?()
            state = consuming ? .ended : .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            activeTouches.subtract(touches)
            guard activeTouches.isEmpty else { return }
            onEnded?()
            state = consuming ? .cancelled : .failed
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            activePresses.formUnion(presses)
            onKeyboardInteraction?()
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            activePresses.subtract(presses)
            onKeyboardInteraction?()
            if activePresses.isEmpty, activeTouches.isEmpty { state = .failed }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            pressesEnded(presses, with: event)
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
            consuming
        }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        override func reset() {
            super.reset()
            if !activeTouches.isEmpty { onEnded?() }
            activeTouches.removeAll(keepingCapacity: true)
            let hadPresses = !activePresses.isEmpty
            activePresses.removeAll(keepingCapacity: true)
            if hadPresses { onKeyboardInteraction?() }
            consuming = false
        }
    }

    /// Each page retains movie audio until it releases its player. One viewer tearing down
    /// must not deactivate the session while a page in another viewer still owns it.
    @MainActor
    enum ImageDetailVideoAudioSession {
        private static var owners: Set<UUID> = []
        private static let worker = ImageDetailVideoAudioSessionWorker()

        static func activate(owner: UUID) {
            VoicePlaybackController.stopAll()
            owners.insert(owner)
            // Repeat requests after activation failure still retry on the next play attempt.
            worker.setDesiredActive(true)
        }

        static func release(owner: UUID) {
            guard owners.remove(owner) != nil, owners.isEmpty else { return }
            worker.setDesiredActive(false)
        }

        static func prepareForVoicePlayback() -> Bool {
            guard owners.isEmpty else { return false }
            // Wait for any queued movie release before voice claims the shared audio session.
            worker.finishPendingRelease()
            return true
        }
    }

    /// The SDK's asynchronous activate/deactivate APIs require iOS 27, while this app
    /// supports iOS 17. Use one non-main serial queue for both blocking operations and their
    /// bookkeeping; no completion can race a later operation on a different executor.
    nonisolated private final class ImageDetailVideoAudioSessionWorker: @unchecked Sendable {
        private let queue = DispatchQueue(
            label: "app.chahua.chat.video-audio-session", qos: .userInitiated)
        private let ownershipLock = NSLock()
        // Protected by ownershipLock; sessionActive is confined to queue.
        private var desiredActive = false
        private var sessionActive = false

        func finishPendingRelease() {
            queue.sync {}
        }

        func setDesiredActive(_ active: Bool) {
            ownershipLock.withLock { desiredActive = active }
            queue.async { [self] in
                // Read current ownership, not the state captured by an old release. A reopen
                // can supersede queued cleanup; a release during a blocking activation queues
                // cleanup after it, so its late completion cannot leave the session active.
                let desired = ownershipLock.withLock { desiredActive }
                guard desired != sessionActive else { return }
                let session = AVAudioSession.sharedInstance()
                if desired {
                    do {
                        try session.setCategory(.playback, mode: .moviePlayback)
                        try session.setActive(true)
                        sessionActive = true
                    } catch {
                        // Playback continues under the default session (silenced by the ring switch).
                    }
                } else {
                    do {
                        try session.setActive(false, options: .notifyOthersOnDeactivation)
                        sessionActive = false
                    } catch {
                        // Retain active bookkeeping so a later ownership transition retries cleanup.
                    }
                }
            }
        }
    }
#endif
