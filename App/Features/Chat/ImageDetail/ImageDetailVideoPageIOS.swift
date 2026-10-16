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
        private let playerController = AVPlayerViewController()
        private let errorLabel = UILabel()
        private let retryButton = UIButton(type: .system)
        private var player: AVPlayer?
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

        init(item: MessageImageItem) {
            self.item = item
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
            mayInteract = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // AVKit's full-screen presentation temporarily reparents the controller's view.
            if playerController.view.superview === self { playerController.view.frame = bounds }
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
            if visible, player == nil, !failed { load() }
            guard visible, selected else {
                player?.pause()
                return
            }
            guard autoplayPending, !failed, let player else { return }
            autoplayPending = false
            ImageDetailVideoAudioSession.activate()
            player.play()
        }

        private func load() {
            guard let url = item.url else {
                showFailure()
                return
            }
            let asset = AVURLAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)
            let player: AVPlayer
            if let existing = self.player {
                player = existing
                player.replaceCurrentItem(with: playerItem)
            } else {
                player = AVPlayer(playerItem: playerItem)
                self.player = player
                playerController.player = player
                // AVKit's own play button may start playback the viewer did not start.
                playbackObservation = player.publisher(for: \.timeControlStatus)
                    .receive(on: DispatchQueue.main)
                    .sink { status in
                        guard status != .paused else { return }
                        ImageDetailVideoAudioSession.activate()
                    }
            }
            setFailed(false)
            statusObservation = playerItem.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak playerItem] status in
                    guard status == .failed, let self, let playerItem,
                        self.player?.currentItem === playerItem
                    else { return }
                    self.showFailure()
                }
            playableCheck?.cancel()
            playableCheck = Task { [weak self, weak playerItem] in
                let playable = (try? await asset.load(.isPlayable)) ?? false
                guard !Task.isCancelled, !playable, let self, let playerItem,
                    self.player?.currentItem === playerItem
                else { return }
                self.showFailure()
            }
        }

        private func showFailure() {
            guard !tornDown, !failed else { return }
            player?.pause()
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
            // Recreate the item (and asset) so a transient network failure is retried.
            failed = false
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

    /// Movie playback audio for the viewer, mirroring `VoicePlaybackController`'s session use:
    /// `.playback` while the viewer plays video, deactivated with
    /// `.notifyOthersOnDeactivation` when the viewer tears down.
    @MainActor
    enum ImageDetailVideoAudioSession {
        private static var active = false

        static func activate() {
            guard !active else { return }
            VoicePlaybackController.stopAll()
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
                active = true
            } catch {
                // Playback continues under the default session (silenced by the ring switch).
            }
        }

        static func deactivate() {
            guard active else { return }
            active = false
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        }
    }
#endif
