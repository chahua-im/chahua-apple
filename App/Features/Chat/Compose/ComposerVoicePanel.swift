import SwiftUI

struct ComposerVoicePanel: View {
    @ObservedObject var recorder: ComposerVoiceRecorder
    @StateObject private var playback = VoicePlaybackController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if recorder.previewURL != nil {
                previewControls
            } else {
                recordingControls
            }
            if let error = playback.error, recorder.phase == .preview {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry playback") {
                    guard let url = recorder.previewURL else { return }
                    Task { await playback.load(url: url) }
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .task(id: recorder.previewURL != nil && scenePhase == .active ? recorder.previewURL : nil) {
            guard scenePhase == .active, let url = recorder.previewURL else {
                playback.stop()
                return
            }
            await playback.load(url: url)
        }
        .onDisappear { playback.stop() }
    }

    private var recordingControls: some View {
        HStack(spacing: 8) {
            if recorder.phase == .requestingPermission {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Waiting for microphone access…")
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(
                        recorder.isLocked ? Text("Recording locked") : Text("Recording…"))
            }
            Text(time(recorder.elapsed))
                .font(.body.monospacedDigit())
                .fixedSize()
                .accessibilityLabel("Recording duration")
                .accessibilityValue(time(recorder.elapsed))
            LiveVoiceWaveform(samples: recorder.liveWaveform)
                .frame(height: 28)
                .accessibilityHidden(true)
        }
        .frame(height: 44)
        .padding(.leading, 6)
        // The left lock target occupies this space during a held iOS recording.
        // Keep the dot and elapsed time to its left, even at narrow widths.
        #if os(iOS)
            .padding(.trailing, recorder.isLocked ? 0 : 64)
        #endif
    }

    private var previewControls: some View {
        HStack(spacing: 8) {
            Button(action: playback.toggle) {
                ZStack {
                    if playback.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .frame(width: 32, height: 32)
                .background(.primary.opacity(0.06), in: Circle())
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(
                playback.isPlaying ? Text("Pause voice message") : Text("Play voice message")
            )
            .disabled(
                recorder.phase != .preview || playback.isLoading || playback.error != nil
                    || playback.duration <= 0
            )
            .modifier(ComposerSendFocus())
            VoiceWaveformScrubber(
                controller: playback, isEnabled: recorder.phase == .preview,
                color: ChahuaTheme.accent, height: 28
            )
            .frame(height: 28)
            Text(
                verbatim: time(
                    playback.isPlaying || playback.position > 0
                        ? playback.position
                        : (playback.duration > 0 ? playback.duration : recorder.elapsed))
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.primary.opacity(0.04), in: Capsule())
            .accessibilityLabel("Recording duration")
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let seconds = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct LiveVoiceWaveform: View {
    let samples: VoiceRecordingWaveform

    var body: some View {
        Canvas { context, size in
            guard size.width.isFinite, size.width > 0, size.height > 0 else { return }
            // Wide Mac windows still fill before the bounded history wraps.
            let step = max(5, size.width / CGFloat(samples.capacity))
            let visibleCount = min(samples.count, max(0, Int(size.width / step)))
            guard visibleCount > 0 else { return }
            var bars = Path()
            // Fixed spacing fills from the left; only a full viewport scrolls.
            // Do not renormalize the window: quiet samples must remain quiet.
            for (offset, sample) in samples.suffix(visibleCount).enumerated() {
                let amplitude = sample.isFinite ? min(1, max(0, sample)) : 0
                let height = max(2, CGFloat(amplitude) * size.height)
                let rect = CGRect(
                    x: CGFloat(offset) * step, y: (size.height - height) / 2, width: 2,
                    height: height)
                bars.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
            }
            context.fill(bars, with: .color(ChahuaTheme.accent))
        }
    }
}
