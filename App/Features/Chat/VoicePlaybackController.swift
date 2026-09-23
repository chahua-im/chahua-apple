import AVFoundation
import ChahuaAudio
import Combine
import Foundation

@MainActor
final class VoicePlaybackController: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var error: String?

    private static weak var active: VoicePlaybackController?
    private static var recordingActive = false
    private var player: AVAudioPlayer?
    private var source: URL?
    private var directory: URL?
    private var generation = UUID()
    private var timer: Timer?
    private var preparation: Task<PreparedVoice, Error>?
    private var observers: [NSObjectProtocol] = []

    init() {
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
        preparation?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    static func stopAll() { active?.pause() }

    static func setRecordingActive(_ recording: Bool) {
        if recording { stopAll() }
        recordingActive = recording
    }

    func load(url: URL) async {
        if source == url, player != nil, error == nil { return }
        stop()
        source = url
        isLoading = true
        let current = generation
        let work = Task.detached(priority: .userInitiated) {
            try await PreparedVoice.make(source: url)
        }
        preparation = work
        do {
            let prepared = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard generation == current, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: prepared.directory)
                return
            }
            directory = prepared.directory
            let audio = try AVAudioPlayer(contentsOf: prepared.url)
            guard audio.duration.isFinite, audio.duration > 0, audio.prepareToPlay() else {
                throw VoicePlaybackError.unreadable
            }
            player = audio
            duration = audio.duration
            waveform = prepared.waveform
            isLoading = false
            preparation = nil
        } catch {
            guard generation == current else { return }
            isLoading = false
            preparation = nil
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directory = nil
            if !(error is CancellationError), !Task.isCancelled {
                self.error = String(localized: "Couldn’t play voice message. Try again.")
            }
        }
    }

    func toggle() {
        guard !Self.recordingActive else {
            error = String(localized: "Finish recording before playing a voice message.")
            return
        }
        guard let player, !isLoading else { return }
        if isPlaying {
            pause()
            return
        }
        Self.active?.pause()
        do {
            #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            #endif
            if player.currentTime >= duration - 0.02 { player.currentTime = 0 }
            guard player.play() else { throw VoicePlaybackError.unreadable }
            Self.active = self
            error = nil
            isPlaying = true
            position = player.currentTime
            timer?.invalidate()
            // Scheduled on the main run loop; no actor-hop task per progress tick.
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePosition() }
            }
        } catch {
            self.error = String(localized: "Couldn’t play voice message. Try again.")
            pause()
        }
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, let player else { return }
        player.currentTime = min(max(0, time), duration)
        position = player.currentTime
    }

    /// Releases downloaded/decoded files and invalidates in-flight loads on cell reuse.
    func stop() {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        pause()
        player = nil
        source = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        isLoading = false
        duration = 0
        position = 0
        waveform = []
        error = nil
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
        if Self.active === self {
            Self.active = nil
            #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    private func updatePosition() {
        guard let player else { return }
        if !player.isPlaying {
            position = duration
            pause()
        } else {
            position = player.currentTime
        }
    }
}

nonisolated private enum VoicePlaybackError: Error { case unreadable }

nonisolated private struct PreparedVoice: Sendable {
    let directory: URL
    let url: URL
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
            let waveform = try VoiceAudioCodec.waveform(input: playback)
            try Task.checkCancellation()
            return Self(directory: directory, url: playback, waveform: waveform)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
