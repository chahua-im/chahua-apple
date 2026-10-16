#if os(macOS)
    import AVFoundation
    import AVKit
    import AppKit
    import Combine

    /// One video page of the AppKit message media viewer.
    ///
    /// The viewer is an AppKit composition (see `ImageDetailPlatformView`), so the video page
    /// uses AVKit's `AVPlayerView` directly instead of hosting SwiftUI's `VideoPlayer`: it lives
    /// inside the viewer's custom hit testing and paging, needs explicit play/pause on page
    /// activation and a hard stop on dismissal, and its native inline controls already provide
    /// play/pause, scrubbing and volume. Full screen and Picture in Picture stay off because the
    /// viewer already covers the window and playback must end when the viewer closes.
    @MainActor
    final class ImageDetailMacVideoView: NSView {
        enum State: Equatable { case idle, loading, ready, failed }

        var onStateChanged: ((State) -> Void)?
        private(set) var state = State.idle
        let playerView = AVPlayerView()

        private let url: URL?
        private let fallbackSize: CGSize?
        private var player: AVPlayer?
        private var itemSubscriptions: Set<AnyCancellable> = []
        private var presentationSize = CGSize.zero
        private var isActive = false

        override var isFlipped: Bool { true }

        init(url: URL?, pixelSize: CGSize?) {
            self.url = url
            fallbackSize = pixelSize
            super.init(frame: .zero)
            setAccessibilityElement(false)
            playerView.controlsStyle = .inline
            playerView.videoGravity = .resizeAspect
            playerView.showsFullScreenToggleButton = false
            playerView.allowsPictureInPicturePlayback = false
            playerView.isHidden = true
            addSubview(playerView)
        }

        required init?(coder: NSCoder) { nil }

        /// Starts the item lazily so off-screen neighbor pages do not stream, and only
        /// autoplays on an inactive-to-active transition so repeated activation never
        /// resumes a video the user paused.
        func setActive(_ active: Bool) {
            guard active != isActive else { return }
            isActive = active
            if active {
                if player == nil { load() }
                player?.play()
            } else {
                player?.pause()
            }
        }

        func retry() {
            load()
            if isActive { player?.play() }
        }

        func togglePlayback() {
            guard let player, state != .failed else { return }
            if player.rate != 0 {
                player.pause()
                return
            }
            if let item = player.currentItem, item.duration.isNumeric,
                item.currentTime() >= item.duration
            {
                player.seek(to: .zero)
            }
            player.play()
        }

        /// Stops playback and releases the item and player; the page is being discarded.
        func stop() {
            isActive = false
            itemSubscriptions.removeAll()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            playerView.player = nil
            player = nil
            playerView.isHidden = true
            update(.idle)
        }

        private func load() {
            itemSubscriptions.removeAll()
            presentationSize = .zero
            guard let url else {
                player?.replaceCurrentItem(with: nil)
                update(.failed)
                return
            }
            let item = AVPlayerItem(url: url)
            if let player {
                player.replaceCurrentItem(with: item)
            } else {
                let player = AVPlayer(playerItem: item)
                self.player = player
                playerView.player = player
            }
            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    switch status {
                    case .readyToPlay: self?.update(.ready)
                    case .failed: self?.update(.failed)
                    default: self?.update(.loading)
                    }
                }
                .store(in: &itemSubscriptions)
            item.publisher(for: \.presentationSize)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] size in
                    guard let self, size != self.presentationSize else { return }
                    self.presentationSize = size
                    self.needsLayout = true
                }
                .store(in: &itemSubscriptions)
            NotificationCenter.default.publisher(
                for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update(.failed) }
            .store(in: &itemSubscriptions)
        }

        private func update(_ newState: State) {
            if newState == .failed { player?.pause() }
            playerView.isHidden = newState == .failed || newState == .idle
            guard newState != state else { return }
            state = newState
            onStateChanged?(newState)
        }

        override func layout() {
            super.layout()
            // The player fills only the aspect-fit video rect so letterbox space keeps the
            // viewer's drag-to-page/dismiss handling; a minimum size keeps the inline
            // controls usable for narrow or tiny videos.
            let candidate = presentationSize.width > 0 ? presentationSize : fallbackSize
            guard let size = candidate, size.width > 0, size.height > 0,
                size.width.isFinite, size.height.isFinite
            else {
                playerView.frame = bounds
                return
            }
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let width = min(bounds.width, max(size.width * scale, 400))
            let height = min(bounds.height, max(size.height * scale, 225))
            playerView.frame = CGRect(
                x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                width: width, height: height)
        }
    }
#endif
