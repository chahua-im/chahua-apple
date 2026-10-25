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
        private let videoCache: VideoFileCache
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
        private var playableCheck: Task<Void, Never>?
        private var visible = false
        private var selected = false
        private var interactive = false
        /// Set when the page becomes the selected page, consumed by the next autoplay, so
        /// returning from the background or a cancelled drag never restarts a paused video.
        private var autoplayPending = false
        private var failed = false
        private var presentingFullScreen = false
        private var tornDown = false
        var mayInteract: (() -> Bool)?

        var isAtFit: Bool { true }
        var childViewController: UIViewController? { playerController }

        init(item: MessageImageItem, mediaContext: AppMediaContext?) {
            self.item = item
            videoCache = mediaContext?.videoCache ?? .unscoped
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
            NotificationCenter.default.removeObserver(self)
            cancelDownload()
            statusObservation?.cancel()
            statusObservation = nil
            playbackObservation?.cancel()
            playbackObservation = nil
            playableCheck?.cancel()
            playableCheck = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            playerController.player = nil
            playerController.delegate = nil
            player = nil
            fileLease = nil
            ImageDetailVideoAudioSession.release(owner: audioSessionOwner)
            mayInteract = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // AVKit's full-screen presentation temporarily reparents the controller's view.
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
            // While AVKit presents full screen the viewer reports itself hidden; playback
            // belongs to that presentation until it ends.
            guard !tornDown, !presentingFullScreen else { return }
            if visible, selected, player == nil, downloadTask == nil, !failed { load() }
            guard visible, selected else {
                cancelDownload()
                player?.pause()
                return
            }
            guard autoplayPending, !failed, let player else { return }
            autoplayPending = false
            ImageDetailVideoAudioSession.activate(owner: audioSessionOwner)
            player.play()
        }

        private func load() {
            guard !tornDown, visible, selected, downloadTask == nil else { return }
            guard let url = item.url else {
                showFailure()
                return
            }
            let previousLease = fileLease
            releasePlayer()
            setFailed(false)
            progressView.update(.indeterminate)
            progressView.isHidden = false
            let id = UUID()
            loadID = id
            let cache = videoCache
            downloadTask = Task { [weak self] in
                if let previousLease { await cache.invalidate(previousLease) }
                do {
                    let lease = try await cache.file(for: url) { [weak self] progress in
                        guard let self, !self.tornDown, self.loadID == id,
                            self.visible, self.selected
                        else { return }
                        self.progressView.update(progress)
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
                    self.showFailure()
                }
            }
        }

        private func installPlayer(url: URL) {
            let asset = AVURLAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            self.player = player
            playerController.player = player
            // AVKit's own play button may start playback the viewer did not start.
            playbackObservation = player.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak player] status in
                    guard status != .paused, let self, !self.tornDown,
                        let player, self.player === player
                    else { return }
                    guard UIApplication.shared.applicationState == .active,
                        self.presentingFullScreen || (self.visible && self.selected)
                    else {
                        self.player?.pause()
                        return
                    }
                    ImageDetailVideoAudioSession.activate(owner: self.audioSessionOwner)
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
            playbackObservation?.cancel()
            playbackObservation = nil
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
            player?.pause()
        }

        private func showFailure() {
            guard !tornDown, !failed else { return }
            player?.pause()
            progressView.isHidden = true
            if let fileLease {
                let cache = videoCache
                Task { await cache.invalidate(fileLease) }
            }
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
            autoplayPending = selected
            load()
            applyPlayback()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator:
                UIViewControllerTransitionCoordinator
        ) {
            presentingFullScreen = true
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, context.isCancelled else { return }
                self.presentingFullScreen = false
                self.applyPlayback()
            }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator:
                UIViewControllerTransitionCoordinator
        ) {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, !context.isCancelled else { return }
                self.presentingFullScreen = false
                self.setNeedsLayout()
                self.applyPlayback()
            }
        }
    }

    /// Each page retains movie audio until it releases its player. One viewer tearing down
    /// must not deactivate the session while a page in another viewer still owns it.
    @MainActor
    private enum ImageDetailVideoAudioSession {
        private static var owners: Set<UUID> = []
        private static let worker = ImageDetailVideoAudioSessionWorker()

        static func activate(owner: UUID) {
            if owners.isEmpty { VoicePlaybackController.stopAll() }
            owners.insert(owner)
            // Repeat requests after activation failure still retry on the next play attempt.
            worker.setDesiredActive(true)
        }

        static func release(owner: UUID) {
            guard owners.remove(owner) != nil, owners.isEmpty else { return }
            worker.setDesiredActive(false)
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
