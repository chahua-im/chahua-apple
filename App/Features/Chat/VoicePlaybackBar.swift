import ChahuaAPI
import SwiftUI

struct VoicePlaybackBar: View {
    @ObservedObject private var session = VoicePlaybackSession.shared
    let onOpenSource: (MessageResponse) -> Void

    var body: some View {
        if let controller = session.controller {
            ActiveVoicePlaybackBar(
                controller: controller, session: session, onOpenSource: onOpenSource)
        }
    }
}

private struct ActiveVoicePlaybackBar: View {
    @ObservedObject var controller: VoicePlaybackController
    @ObservedObject var session: VoicePlaybackSession
    let onOpenSource: (MessageResponse) -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                Button {
                    controller.toggle()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(
                    controller.isPlaying ? "Pause voice message" : "Play voice message")
                Button {
                    if let message = controller.message { onOpenSource(message) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            controller.message?.sender.name
                                ?? AppLanguage.localized("Voice message")
                        )
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(time(controller.position)) / \(time(controller.duration))")
                                .monospacedDigit()
                            if let sentAt = controller.message?.createdAt {
                                Text(sentAt, style: .time)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityHint("Jump to source message")
                Menu {
                    ForEach(VoicePlaybackSession.speeds, id: \.self) { speed in
                        Button {
                            session.setSpeed(speed)
                        } label: {
                            if session.speed == speed {
                                Label("\(speed.formatted())×", systemImage: "checkmark")
                            } else {
                                Text("\(speed.formatted())×")
                            }
                        }
                    }
                } label: {
                    Text("\(session.speed.formatted())×").font(.subheadline.monospacedDigit())
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Playback speed")
                Button {
                    session.dismiss()
                } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close voice player")
            }
            if let error = controller.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if controller.duration > 0 {
                Slider(
                    value: Binding(get: { controller.position }, set: { controller.seek(to: $0) }),
                    in: 0...controller.duration
                )
                .accessibilityLabel("Voice playback position")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }

    private func time(_ value: TimeInterval) -> String {
        let seconds = value.isFinite ? max(0, Int(value)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
