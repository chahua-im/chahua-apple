import ChahuaAPI
import SwiftUI

struct VoicePlaybackBar: View {
    let controller: VoicePlaybackController
    @Environment(\.voicePlaybackHeaderRoute) private var route

    var body: some View {
        if let route, let message = controller.message {
            VoicePlaybackCapsule(controller: controller, route: route, message: message)
        }
    }
}

struct VoicePlaybackCapsule: View {
    @ObservedObject var controller: VoicePlaybackController
    let route: VoicePlaybackHeaderRoute
    let message: MessageResponse
    @State private var sourceUnavailable = false
    private let sourceChatName: String?

    init(
        controller: VoicePlaybackController, route: VoicePlaybackHeaderRoute,
        message: MessageResponse
    ) {
        self.controller = controller
        self.route = route
        self.message = message
        sourceChatName = route.chatName(message.chatId)
    }

    static var nominalHeight: CGFloat {
        #if os(macOS)
            36
        #else
            52
        #endif
    }

    static let blue = Color(red: 43 / 255, green: 122 / 255, blue: 205 / 255)

    private var playDiameter: CGFloat {
        #if os(macOS)
            26
        #else
            36
        #endif
    }

    private var targetSize: CGFloat {
        #if os(macOS)
            32
        #else
            44
        #endif
    }

    private var progress: Double {
        guard controller.duration > 0 else { return 0 }
        return min(1, max(0, controller.position / controller.duration))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: controller.toggle) {
                ZStack {
                    Circle().fill(Self.blue)
                    if controller.wantsPlayback {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: playDiameter * 0.36, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: playDiameter, height: playDiameter)
                .frame(width: targetSize, height: targetSize)
                .contentShape(Circle())
            }
            .accessibilityLabel(playbackLabel)
            Button {
                route.open(message, {}, { sourceUnavailable = true })
            } label: {
                sourceLabel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("Jump to source message")
            Button {
                let session = VoicePlaybackSession.shared
                if session.controller === controller { session.dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: playDiameter - 6, height: playDiameter - 6)
                    .background(.primary.opacity(0.07), in: Circle())
                    .frame(width: targetSize, height: targetSize)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Stop voice message")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, (Self.nominalHeight - targetSize) / 2)
        .frame(minHeight: Self.nominalHeight)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) {
            GeometryReader { geometry in
                Capsule(style: .circular)
                    .fill(Self.blue.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule(style: .circular).fill(Self.blue)
                            .frame(width: geometry.size.width * progress)
                    }
            }
            .frame(height: 2.5)
            .padding(.horizontal, Self.nominalHeight / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .modifier(ChatGlassSurface(shape: Capsule(style: .circular)))
        .accessibilityIdentifier("voice-playback-capsule")
        .alert("Unable to open", isPresented: $sourceUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This message is unavailable or you do not have access.")
        }
    }

    private var playbackLabel: Text {
        if controller.wantsPlayback { return Text("Cancel audio loading") }
        return controller.isPlaying ? Text("Pause voice message") : Text("Play voice message")
    }

    private var sender: Text {
        if message.sender.uid == route.currentUserID { return Text("You") }
        return Text(
            verbatim: message.sender.name ?? AppLanguage.localized("User \(message.sender.uid)"))
    }

    private var chat: Text {
        if let sourceChatName { return Text(verbatim: sourceChatName) }
        return Text("Conversation")
    }

    private var time: some View {
        Text(
            verbatim:
                "\(voicePlaybackTime(controller.position)) / \(voicePlaybackTime(controller.duration))"
        )
        .monospacedDigit()
        .fixedSize()
    }

    private var sourceLabel: some View {
        #if os(macOS)
            HStack(spacing: 4) {
                sender.fontWeight(.semibold).lineLimit(1)
                Text("·").foregroundStyle(.secondary)
                Text("Voice message").foregroundStyle(.secondary).lineLimit(1)
                Text("·").foregroundStyle(.secondary)
                chat.foregroundStyle(.secondary).lineLimit(1)
                time.foregroundStyle(.secondary)
            }
            .font(.subheadline)
        #else
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    sender.fontWeight(.semibold).lineLimit(1)
                    Text("·").foregroundStyle(.secondary)
                    Text("Voice message").foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.subheadline)
                HStack(spacing: 4) {
                    chat.lineLimit(1)
                    Text("·")
                    time
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        #endif
    }
}

enum VoicePlaybackMotion {
    static var transition: AnyTransition { .offset(y: -10).combined(with: .opacity) }

    static func animation(showing: Bool, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return showing ? .easeOut(duration: 0.24) : .easeIn(duration: 0.20)
    }
}

func voicePlaybackTime(_ value: TimeInterval) -> String {
    let seconds = value.isFinite ? max(0, Int(value)) : 0
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
