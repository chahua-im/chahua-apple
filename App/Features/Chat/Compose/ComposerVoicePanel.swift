import SwiftUI

struct ComposerVoicePanel: View {
    @ObservedObject var recorder: ComposerVoiceRecorder
    let isEnabled: Bool
    let onSendVoice: (URL) async -> Bool
    @StateObject private var playback = VoicePlaybackController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if recorder.phase == .recording {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text("Recording…")
                    Spacer(minLength: 0)
                    duration(recorder.elapsed)
                } else if recorder.phase == .requestingPermission {
                    ProgressView().controlSize(.small)
                    Text("Waiting for microphone access…")
                } else if recorder.phase == .sending {
                    ProgressView().controlSize(.small)
                    Text("Sending voice message…")
                } else {
                    Text("Voice message")
                    Spacer(minLength: 0)
                    duration(playback.duration > 0 ? playback.duration : recorder.elapsed)
                }
            }
            .font(.subheadline)

            HStack(spacing: 8) {
                Button {
                    playback.stop()
                    recorder.discard()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Discard voice message")
                .disabled(recorder.phase == .sending)
                .modifier(ComposerSendFocus())

                if recorder.phase == .recording {
                    Spacer(minLength: 0)
                    Button {
                        recorder.stop()
                    } label: {
                        Label("Stop recording", systemImage: "stop.fill")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(ChahuaTheme.accent)
                    .modifier(ComposerSendFocus())
                } else if recorder.phase == .preview {
                    previewControls
                    Button {
                        playback.stop()
                        recorder.send(using: onSendVoice)
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .foregroundStyle(isEnabled ? ChahuaTheme.accent : .secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Send voice message")
                    .disabled(!isEnabled)
                    .modifier(ComposerSendFocus())
                } else {
                    Spacer(minLength: 0)
                }
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
        .padding(12)
        .task(id: recorder.phase == .preview && scenePhase == .active ? recorder.previewURL : nil) {
            guard recorder.phase == .preview, scenePhase == .active, let url = recorder.previewURL else {
                playback.stop()
                return
            }
            await playback.load(url: url)
        }
        .onDisappear { playback.stop() }
    }

    private var previewControls: some View {
        HStack(spacing: 4) {
            Button(action: playback.toggle) {
                Group {
                    if playback.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(playback.isPlaying ? Text("Pause voice message") : Text("Play voice message"))
            .disabled(playback.isLoading || playback.error != nil || playback.duration <= 0)
            .modifier(ComposerSendFocus())
            VStack(alignment: .leading, spacing: 0) {
                Slider(
                    value: Binding(get: { min(playback.position, max(playback.duration, 0.01)) }, set: playback.seek),
                    in: 0...max(playback.duration, 0.01)
                )
                .tint(ChahuaTheme.accent)
                .accessibilityLabel("Voice message position")
                .accessibilityValue(time(playback.position))
                .disabled(playback.isLoading || playback.duration <= 0 || playback.error != nil)
                Text(time(playback.position))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private func duration(_ seconds: TimeInterval) -> some View {
        Text(time(seconds))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityLabel("Recording duration")
            .accessibilityValue(time(seconds))
    }

    private func time(_ seconds: TimeInterval) -> String {
        let seconds = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
