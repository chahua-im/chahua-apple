import AVFoundation
import Combine
import Foundation

@MainActor
final class ComposerVoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum Phase {
        case idle, requestingPermission, recording, preview, sending
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var previewURL: URL?
    @Published var error: String?

    var isActive: Bool { phase != .idle }
    var isBusy: Bool { phase != .idle && phase != .preview }

    private var recorder: AVAudioRecorder?
    private var files: ComposerVoiceFiles?
    private var generation = UUID()
    private var permissionTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var discardAfterSend = false
    private var sceneIsActive = false
    private var permissionWasGranted = false
    private var observations: Set<AnyCancellable> = []
    private var ownsRecordingSession = false
    #if os(iOS)
    private var ownsAudioSession = false
    #endif

    override init() {
        super.init()
        #if os(iOS)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
                self?.suspend()
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: reason) == .oldDeviceUnavailable else { return }
                self?.suspend()
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.suspend() }
            .store(in: &observations)
        #endif
    }

    isolated deinit {
        permissionTask?.cancel()
        sendTask?.cancel()
        finishRecording()
    }

    func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        if !active, phase == .recording {
            stop()
        } else if active, phase == .requestingPermission, permissionWasGranted {
            beginRecording()
        }
    }

    func start() {
        guard phase == .idle else { return }
        error = nil
        phase = .requestingPermission
        generation = UUID()
        let request = generation
        permissionWasGranted = false
        permissionTask = Task { [weak self] in
            let granted = await Self.requestPermission()
            guard !Task.isCancelled, let self, self.generation == request,
                  self.phase == .requestingPermission else { return }
            self.permissionTask = nil
            guard granted else {
                self.phase = .idle
                self.error = String(localized: "Allow microphone access in Settings to record voice messages.")
                return
            }
            self.permissionWasGranted = true
            if self.sceneIsActive { self.beginRecording() }
        }
    }

    func stop() {
        guard phase == .recording, let recorder else { return }
        elapsed = max(elapsed, recorder.currentTime)
        finishRecording()
        // Flutter uses the same 500 ms minimum for a usable voice draft.
        guard elapsed >= 0.5 else {
            discard()
            error = String(localized: "Record for at least half a second before sending.")
            return
        }
        previewURL = files?.recordingURL
        phase = .preview
    }

    func send(using onSendVoice: @escaping (URL) async -> Bool) {
        guard phase == .preview, let files else { return }
        error = nil
        phase = .sending
        sendTask = Task {
            // The backend accepts AAC/M4A and canonicalizes it to Ogg Opus.
            // Keep the source alive until the outbox's durable copy is complete.
            let sent = await onSendVoice(files.recordingURL)
            self.sendTask = nil
            if sent || self.discardAfterSend {
                self.discardAfterSend = false
                self.phase = .preview
                self.discard()
            } else {
                self.phase = .preview
                self.error = String(localized: "Couldn’t send the voice message. Your recording is ready to try again.")
            }
        }
    }

    func discard() {
        // An in-flight enqueue owns the source until its durable copy is complete.
        guard phase != .sending else {
            discardAfterSend = true
            return
        }
        generation = UUID()
        permissionWasGranted = false
        permissionTask?.cancel()
        permissionTask = nil
        sendTask?.cancel()
        sendTask = nil
        finishRecording()
        previewURL = nil
        files = nil
        elapsed = 0
        phase = .idle
        error = nil
    }

    /// Stop capture without losing a valid draft or automatically restarting capture.
    func suspend() {
        switch phase {
        case .requestingPermission:
            discard()
        case .recording:
            stop()
        case .idle, .preview, .sending:
            break
        }
    }

    private static func requestPermission() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    private func beginRecording() {
        do {
            VoicePlaybackController.setRecordingActive(true)
            ownsRecordingSession = true
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            ownsAudioSession = true
            #endif
            let files = try ComposerVoiceFiles()
            self.files = files
            let recorder = try AVAudioRecorder(url: files.recordingURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            self.recorder = recorder
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else {
                throw CocoaError(.fileWriteUnknown)
            }
            elapsed = 0
            phase = .recording
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    guard let self, self.phase == .recording else { return }
                    if let recorder = self.recorder, recorder.isRecording {
                        self.elapsed = recorder.currentTime
                    }
                }
            }
        } catch {
            discard()
            self.error = String(localized: "Couldn’t start recording. Check your microphone and try again.")
        }
    }

    private func finishRecording() {
        clockTask?.cancel()
        clockTask = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        #if os(iOS)
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
        #endif
        if ownsRecordingSession {
            VoicePlaybackController.setRecordingActive(false)
            ownsRecordingSession = false
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url, self.phase == .recording else { return }
            if flag {
                self.stop()
            } else {
                self.discard()
                self.error = String(localized: "Recording was interrupted. Please record your message again.")
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url else { return }
            self.discard()
            self.error = String(localized: "Recording was interrupted. Please record your message again.")
        }
    }
}

/// Owns the temporary draft through recording, preview and the durable outbox copy.
private final class ComposerVoiceFiles: Sendable {
    nonisolated let directory: URL
    nonisolated let recordingURL: URL

    nonisolated init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString)", isDirectory: true)
        recordingURL = directory.appendingPathComponent("recording.m4a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
