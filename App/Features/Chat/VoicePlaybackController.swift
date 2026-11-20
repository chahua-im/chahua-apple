import AVFoundation
import ChahuaAPI
import ChahuaAudio
import Combine
import Foundation

@MainActor
final class VoicePlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var error: String?
    @Published private(set) var wantsPlayback = false
    @Published private(set) var hasPlayed = false
    private(set) var message: MessageResponse?
    private(set) var identity: VoicePlaybackSession.Identity?

    /// Adopted players are bound to a message, not an attachment shared by several messages.
    static func controller(
        for message: MessageResponse?, url: URL?, reusing controller: VoicePlaybackController?
    ) -> VoicePlaybackController {
        let session = VoicePlaybackSession.shared
        let identity = message.map(VoicePlaybackSession.Identity.init)
        if let identity, let retained = session.controller, retained.identity == identity {
            return retained
        }
        if let controller, controller.identity == identity { return controller }
        let next = VoicePlaybackController()
        next.message = message
        next.identity = identity
        next.source = url
        next.restoreProgress()
        return next
    }

    // Normally there is just one attached row. Additional windows can show the
    // same adopted controller without either row being able to tear the other down.
    private var firstRow: ObjectIdentifier?
    private var additionalRows: Set<ObjectIdentifier> = []

    func retainRow(_ row: ObjectIdentifier) {
        if firstRow == nil {
            firstRow = row
        } else if firstRow != row {
            additionalRows.insert(row)
        }
    }

    func releaseRow(_ row: ObjectIdentifier) {
        if firstRow == row {
            firstRow = additionalRows.popFirst()
        } else {
            additionalRows.remove(row)
        }
        releaseIfUnowned()
    }

    func releaseIfUnowned() {
        if firstRow == nil, VoicePlaybackSession.shared.controller !== self { stop() }
    }

    func setSpeed(_ speed: Float) {
        player?.rate = speed
    }

    private static weak var requested: VoicePlaybackController?
    private static var recordingActive = false
    private var player: AVAudioPlayer?
    private var source: URL?
    private var preparedURL: URL?
    private var directory: URL?
    private var generation = UUID()
    private var ownsAudioSession = false
    private var timer: Timer?
    private var preparation: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        #if os(iOS)
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
                ) { [weak self] notification in
                    guard
                        (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                            == AVAudioSession.InterruptionType.began.rawValue
                    else { return }
                    MainActor.assumeIsolated { self?.pause() }
                })
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
                ) { [weak self] notification in
                    guard
                        (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                            == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                    else { return }
                    MainActor.assumeIsolated { self?.pause() }
                })
        #endif
    }

    deinit {
        timer?.invalidate()
        #if os(iOS)
            if ownsAudioSession {
                player?.stop()
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation)
            }
        #endif
        preparation?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    static func stopAll() { requested?.pause() }

    static func setRecordingActive(_ recording: Bool) {
        if recording { stopAll() }
        recordingActive = recording
    }

    func load(url: URL) async {
        guard !Task.isCancelled else { return }
        await prepare(url: url)?.value
    }

    private func prepare(url requestedURL: URL) -> Task<Void, Never>? {
        let session = VoicePlaybackSession.shared
        let url = session.controller === self ? source ?? requestedURL : requestedURL
        if source == url {
            if preparedURL != nil {
                if error != nil { error = nil }
                return nil
            }
            if let preparation { return preparation }
        } else {
            stop()
            source = url
            restoreProgress()
        }
        error = nil
        isLoading = true
        let current = generation
        let task = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                try await PreparedVoice.make(source: url)
            }
            do {
                let prepared = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard let self, generation == current, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: prepared.directory)
                    return
                }
                directory = prepared.directory
                preparedURL = prepared.url
                duration = prepared.duration
                waveform = prepared.waveform
                position = min(position, duration)
                isLoading = false
                preparation = nil
                startRequestedPlayback()
            } catch {
                guard let self, generation == current, !Task.isCancelled else { return }
                preparation = nil
                isLoading = false
                if wantsPlayback {
                    failPlayback()
                } else {
                    self.error = AppLanguage.localized("Couldn’t play voice message. Try again.")
                }
            }
        }
        preparation = task
        return task
    }

    func toggle() {
        guard let source else { return }
        toggle(url: source)
    }

    func toggle(url: URL) {
        if isPlaying || wantsPlayback {
            pause()
            return
        }
        guard !Self.recordingActive else {
            error = AppLanguage.localized("Finish recording before playing a voice message.")
            return
        }
        Self.requested?.pause()
        _ = prepare(url: url)
        if identity != nil { VoicePlaybackSession.shared.adopt(self) }
        Self.requested = self
        wantsPlayback = true
        startRequestedPlayback()
    }

    private func startRequestedPlayback() {
        guard wantsPlayback, Self.requested === self, let preparedURL else { return }
        do {
            #if os(iOS)
                guard ImageDetailVideoAudioSession.prepareForVoicePlayback() else {
                    throw VoicePlaybackError.unreadable
                }
            #endif
            let player = try AVAudioPlayer(contentsOf: preparedURL)
            player.delegate = self
            player.enableRate = true
            #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                ownsAudioSession = true
            #endif
            player.rate = VoicePlaybackSession.shared.speed
            player.currentTime = position >= duration ? 0 : position
            guard player.prepareToPlay() else { throw VoicePlaybackError.unreadable }
            guard player.play() else { throw VoicePlaybackError.unreadable }
            self.player = player
            error = nil
            wantsPlayback = false
            isPlaying = true
            position = player.currentTime
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePosition() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            failPlayback()
        }
    }

    private func failPlayback() {
        pause()
        error = AppLanguage.localized("Couldn’t play voice message. Try again.")
        VoicePlaybackSession.shared.remove(self)
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, duration > 0 else { return }
        position = min(max(0, time), duration)
        player?.currentTime = position
        rememberProgress()
    }

    private var isStopped: Bool {
        player == nil && preparation == nil && source == nil && directory == nil
            && !isLoading && !isPlaying && !wantsPlayback && duration == 0 && position == 0
            && waveform.isEmpty && error == nil && !hasPlayed
    }

    /// Releases playback resources on row disposal or account teardown.
    func stop() {
        guard !isStopped else { return }
        generation = UUID()
        VoicePlaybackSession.shared.remove(self)
        preparation?.cancel()
        preparation = nil
        pause(savingPosition: false)
        player = nil
        preparedURL = nil
        source = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        isLoading = false
        duration = 0
        position = 0
        waveform = []
        error = nil
        hasPlayed = false
    }

    func pause() { pause(savingPosition: true) }

    private func pause(savingPosition: Bool) {
        let wasRequested = isPlaying || wantsPlayback
        if isPlaying, let player, player.isPlaying || player.currentTime > 0 {
            position = player.currentTime
        }
        // Stop output before surrendering the session; position is owned by the controller.
        player?.stop()
        player = nil
        if wantsPlayback { wantsPlayback = false }
        if isPlaying { isPlaying = false }
        timer?.invalidate()
        timer = nil
        if Self.requested === self { Self.requested = nil }
        if savingPosition, wasRequested { rememberProgress() }
        if ownsAudioSession {
            ownsAudioSession = false
            #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    private func restoreProgress() {
        guard let identity, let saved = VoicePlaybackSession.shared.progress[identity] else {
            return
        }
        position = saved.position
        hasPlayed = saved.hasPlayed
    }

    private func rememberProgress() {
        guard let identity else { return }
        VoicePlaybackSession.shared.progress[identity] = .init(
            position: position, hasPlayed: hasPlayed)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, isPlaying, let player = self.player,
                ObjectIdentifier(player) == id, !player.isPlaying
            else { return }
            if flag {
                pause(savingPosition: false)
                position = 0
                hasPlayed = true
                rememberProgress()
                VoicePlaybackSession.shared.remove(self)
            } else {
                failPlayback()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, let player = self.player, isPlaying, ObjectIdentifier(player) == id
            else { return }
            failPlayback()
        }
    }

    private func updatePosition() {
        guard let player, player.isPlaying else { return }
        position = player.currentTime
    }
}

nonisolated private enum VoicePlaybackError: Error { case unreadable }

nonisolated private struct PreparedVoice: Sendable {
    let directory: URL
    let url: URL
    let duration: TimeInterval
    let waveform: [Float]

    static func make(source: URL) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chahua-voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let original: URL
            if source.isFileURL {
                original = source
            } else {
                guard ["https", "http"].contains(source.scheme?.lowercased() ?? "") else {
                    throw VoicePlaybackError.unreadable
                }
                let (download, response) = try await URLSession.shared.download(from: source)
                defer { try? FileManager.default.removeItem(at: download) }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
                else {
                    throw VoicePlaybackError.unreadable
                }
                original = directory.appendingPathComponent("original").appendingPathExtension(
                    source.pathExtension.isEmpty ? "audio" : source.pathExtension)
                try FileManager.default.moveItem(at: download, to: original)
            }
            try Task.checkCancellation()
            let playback: URL
            if try VoiceAudioCodec.isOgg(original) {
                playback = directory.appendingPathComponent("playback.m4a")
                try VoiceAudioCodec.decode(input: original, output: playback)
            } else {
                playback = original
            }
            let audio = try VoiceAudioCodec.waveform(input: playback)
            try Task.checkCancellation()
            return Self(
                directory: directory, url: playback, duration: audio.duration,
                waveform: audio.samples)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
