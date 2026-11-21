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
        enum State: Equatable { case idle, loading, ready, notDownloaded, failed }

        var onStateChanged: ((State) -> Void)?
        private(set) var state = State.idle
        let playerView = AVPlayerView()

        private let url: URL?
        private let fallbackSize: CGSize?
        private let videoCache: VideoFileCache?
        private var loadPolicy: MediaLoadPolicy
        private var userInitiated: Bool
        private var policyObservation: AnyCancellable?
        private let progressView = VideoDownloadProgressView()
        private var downloadTask: Task<Void, Never>?
        private var loadID = UUID()
        private var fileLease: VideoFileLease?
        private var player: AVPlayer?
        private var itemSubscriptions: Set<AnyCancellable> = []
        private var presentationSize = CGSize.zero
        private var isActive = false
        private var applicationIsActive = NSApp.isActive
        private var autoplayPending = false

        override var isFlipped: Bool { true }

        init(
            url: URL?, pixelSize: CGSize?, mediaContext: AppMediaContext?, userInitiated: Bool
        ) {
            self.url = url
            fallbackSize = pixelSize
            videoCache = mediaContext?.videoCache
            loadPolicy = mediaContext?.loadPolicy ?? .cacheOnly
            self.userInitiated = userInitiated
            super.init(frame: .zero)
            setAccessibilityElement(false)
            playerView.controlsStyle = .inline
            playerView.videoGravity = .resizeAspect
            playerView.showsFullScreenToggleButton = false
            playerView.allowsPictureInPicturePlayback = false
            playerView.isHidden = true
            addSubview(playerView)
            progressView.isHidden = true
            addSubview(progressView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationResignedActive),
                name: NSApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationBecameActive),
                name: NSApplication.didBecomeActiveNotification, object: nil)
            policyObservation = mediaContext?.loadPolicyChanges.sink { [weak self] policy in
                self?.applyLoadPolicy(policy)
            }
        }

        required init?(coder: NSCoder) { nil }

        /// Only the selected, attached page downloads. Selection arms autoplay once; returning
        /// from the background does not resume a paused video or autoplay a late completion.
        func setActive(_ active: Bool) {
            guard active != isActive else { return }
            isActive = active
            autoplayPending = active
            applyPlayback()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyPlayback()
        }

        private func applyPlayback() {
            guard isActive, applicationIsActive, window != nil else {
                cancelDownload()
                player?.pause()
                return
            }
            if player == nil, downloadTask == nil, state == .idle { load() }
            if autoplayPending, let player, state != .failed {
                autoplayPending = false
                VoicePlaybackController.stopAll()
                player.play()
            }
        }

        func retry() {
            guard isActive, applicationIsActive, window != nil else { return }
            userInitiated = true
            autoplayPending = true
            load()
        }

        @objc private func applicationResignedActive() {
            applicationIsActive = false
            autoplayPending = false
            applyPlayback()
        }

        @objc private func applicationBecameActive() {
            applicationIsActive = true
            applyPlayback()
        }

        func togglePlayback() {
            guard isActive, applicationIsActive, let player, state != .failed else { return }
            if player.rate != 0 {
                player.pause()
                return
            }
            if let item = player.currentItem, item.duration.isNumeric,
                item.currentTime() >= item.duration
            {
                player.seek(to: .zero)
            }
            VoicePlaybackController.stopAll()
            player.play()
        }

        /// Stops playback and releases the item and player; the page is being discarded.
        func stop() {
            isActive = false
            autoplayPending = false
            policyObservation = nil
            cancelDownload()
            releasePlayer()
            update(.idle)
        }

        private func applyLoadPolicy(_ policy: MediaLoadPolicy) {
            let before = loadPolicy.allowsNetwork(isVideo: true, userInitiated: userInitiated)
            loadPolicy = policy
            let after = policy.allowsNetwork(isVideo: true, userInitiated: userInitiated)
            guard before != after, url?.isFileURL == false, player == nil else { return }
            cancelDownload()
            if state == .notDownloaded || state == .failed { update(.idle) }
            applyPlayback()
        }

        private func load() {
            guard isActive, applicationIsActive, window != nil, downloadTask == nil else { return }
            let previousLease = fileLease
            releasePlayer()
            presentationSize = .zero
            guard let url else {
                update(.failed)
                return
            }
            guard url.isFileURL || videoCache != nil else {
                update(.notDownloaded)
                return
            }
            let allowsNetwork = loadPolicy.allowsNetwork(
                isVideo: true, userInitiated: userInitiated)
            update(.loading)
            progressView.update(.indeterminate)
            if !allowsNetwork && !url.isFileURL { progressView.isHidden = true }
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
                            guard let self, self.loadID == id, self.isActive,
                                self.applicationIsActive, self.window != nil
                            else { return }
                            self.progressView.update(progress)
                        }
                    } else {
                        throw VideoFileCache.CacheMiss.notDownloaded
                    }
                    guard !Task.isCancelled, let self, self.loadID == id, self.isActive,
                        self.applicationIsActive, self.window != nil
                    else { return }
                    self.downloadTask = nil
                    self.fileLease = lease
                    self.installPlayer(url: lease.url)
                    self.applyPlayback()
                } catch {
                    guard !Task.isCancelled, let self, self.loadID == id, self.isActive,
                        self.applicationIsActive, self.window != nil
                    else { return }
                    self.downloadTask = nil
                    self.update(error is VideoFileCache.CacheMiss ? .notDownloaded : .failed)
                }
            }
        }

        private func installPlayer(url: URL) {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            self.player = player
            playerView.player = player
            playerView.isHidden = false
            progressView.update(.indeterminate)
            // AVKit can also start the player from its native inline controls.
            player.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak player] status in
                    guard let self, let player, self.player === player,
                        status != .paused, player.timeControlStatus != .paused
                    else { return }
                    VoicePlaybackController.stopAll()
                }
                .store(in: &itemSubscriptions)
            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak item] status in
                    guard let self, let item, self.player?.currentItem === item else { return }
                    switch status {
                    case .readyToPlay: self.update(.ready)
                    case .failed: self.update(.failed)
                    default: self.update(.loading)
                    }
                }
                .store(in: &itemSubscriptions)
            item.publisher(for: \.presentationSize)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak item] size in
                    guard let self, let item, self.player?.currentItem === item,
                        size != self.presentationSize
                    else { return }
                    self.presentationSize = size
                    self.needsLayout = true
                }
                .store(in: &itemSubscriptions)
            NotificationCenter.default.publisher(
                for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] _ in
                guard let self, let item, self.player?.currentItem === item else { return }
                self.update(.failed)
            }
            .store(in: &itemSubscriptions)
        }

        private func cancelDownload() {
            guard downloadTask != nil else { return }
            loadID = UUID()
            downloadTask?.cancel()
            downloadTask = nil
            update(.idle)
        }

        private func releasePlayer() {
            itemSubscriptions.removeAll()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            playerView.player = nil
            player = nil
            fileLease = nil
            playerView.isHidden = true
        }

        private func update(_ newState: State) {
            if newState == .failed {
                player?.pause()
                if let fileLease, let videoCache {
                    Task { await videoCache.invalidate(fileLease) }
                }
            }
            progressView.isHidden = newState != .loading
            playerView.isHidden = player == nil || newState == .failed || newState == .idle
            guard newState != state else { return }
            state = newState
            onStateChanged?(newState)
        }

        override func layout() {
            super.layout()
            progressView.frame = CGRect(
                x: bounds.midX - 32, y: bounds.midY - 32, width: 64, height: 64)
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
