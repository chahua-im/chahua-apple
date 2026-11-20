import SwiftUI

/// Shared by measurement and rendering; audio decoding never participates in row layout.
struct VoiceMessageBubbleMetrics {
    let bodySize: CGFloat
    let captionSize: CGFloat
    var metadataSize: CGSize = .zero

    // Flutter uses a 32pt circle, 10pt gap and 173pt waveform; the PWA caps its
    // voice content at 280pt. Keep that shape with Apple's 44pt touch target.
    static func preferredWidth(bodySize: CGFloat) -> CGFloat { 280 * max(1, bodySize / 17) }
    var targetSize: CGFloat { max(44, ceil(bodySize * 44 / 17)) }
    var circleSize: CGFloat { max(32, bodySize * 32 / 17) }
    var waveformHeight: CGFloat { max(32, ceil(bodySize * 32 / 17)) }
    var statusHeight: CGFloat { max(ceil(captionSize * 1.5), metadataSize.height) }
    func isStacked(width: CGFloat) -> Bool { width < targetSize + 10 + 80 }
    func height(for width: CGFloat) -> CGFloat {
        targetSize + (isStacked(width: width) ? waveformHeight + 6 : 0) + 6 + statusHeight
    }

    func playbackButtonContains(
        _ point: CGPoint, in audioFrame: CGRect, layoutDirection: LayoutDirection
    ) -> Bool {
        let radius = targetSize / 2
        let centerX =
            isStacked(width: audioFrame.width)
            ? audioFrame.midX
            : layoutDirection == .rightToLeft ? audioFrame.maxX - radius : audioFrame.minX + radius
        let dx = point.x - centerX
        let dy = point.y - audioFrame.minY - radius
        return dx * dx + dy * dy <= radius * radius
    }

    func displayedMetadataSize(for width: CGFloat) -> CGSize {
        let available = max(0, width)
        let gap = min(8, available / 10)
        let durationWidth = min(captionSize * 7.5, available / 2)
        let maximum = max(0, available - durationWidth - gap)
        guard metadataSize.width > 0 else { return .zero }
        let scale = min(1, maximum / metadataSize.width)
        return CGSize(width: metadataSize.width * scale, height: metadataSize.height * scale)
    }

    func statusWidth(for width: CGFloat) -> CGFloat {
        let metadataWidth = displayedMetadataSize(for: width).width
        return max(0, width - metadataWidth - (metadataWidth > 0 ? min(8, max(0, width) / 10) : 0))
    }
}

/// The one shared playback surface. Native timelines host only this control:
/// their cached row geometry remains authoritative, with no SwiftUI row sizing.
struct VoiceMessageBubbleView: View {
    @ObservedObject var controller: VoicePlaybackController
    let url: URL?
    let isOutgoing: Bool
    let isActive: Bool
    let metrics: VoiceMessageBubbleMetrics
    let localeIdentifier: String
    let layoutDirection: LayoutDirection
    private let session = VoicePlaybackSession.shared

    private struct LoadKey: Hashable {
        let url: URL?
        let controllerID: ObjectIdentifier
        let active: Bool
    }

    private var accent: Color { isOutgoing ? .white : .accentColor }
    private var canPlay: Bool {
        isActive && url != nil && !controller.isLoading && controller.error == nil
            && controller.duration > 0
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 6) {
                if metrics.isStacked(width: geometry.size.width) {
                    VStack(spacing: 6) {
                        playbackButton
                        waveform
                            .frame(height: metrics.waveformHeight)
                    }
                } else {
                    HStack(spacing: 10) {
                        playbackButton
                        waveform
                            .frame(height: metrics.targetSize)
                    }
                }
                HStack(spacing: 4) {
                    if controller.hasPlayed {
                        Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                    }
                    Text(status)
                }
                .font(.system(size: metrics.captionSize))
                .monospacedDigit()
                .foregroundStyle(accent.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(
                    width: metrics.statusWidth(for: geometry.size.width),
                    height: metrics.statusHeight, alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityHidden(canPlay)
            }
            .frame(
                width: geometry.size.width, height: metrics.height(for: geometry.size.width),
                alignment: .top)
        }
        .clipped()
        .allowsHitTesting(isActive)
        .accessibilityElement(children: .contain)
        .environment(\.locale, Locale(identifier: localeIdentifier))
        .environment(\.layoutDirection, layoutDirection)
        .task(id: LoadKey(url: url, controllerID: ObjectIdentifier(controller), active: isActive)) {
            guard isActive, let url else { return }
            await controller.load(url: url)
        }
    }

    private var playbackButton: some View {
        let foreground: Color = isOutgoing ? VoicePlaybackCapsule.blue : .white
        return Button {
            guard let url else { return }
            controller.toggle(url: url)
        } label: {
            ZStack {
                Circle().fill(isOutgoing ? .white : VoicePlaybackCapsule.blue)
                if controller.wantsPlayback {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else {
                    Image(
                        systemName: url == nil
                            ? "exclamationmark"
                            : controller.error != nil
                                ? "arrow.clockwise"
                                : controller.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.system(size: metrics.bodySize, weight: .semibold))
                    .foregroundStyle(foreground)
                }
            }
            .frame(width: metrics.circleSize, height: metrics.circleSize)
            .frame(width: metrics.targetSize, height: metrics.targetSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isActive || url == nil)
        .accessibilityLabel(playbackLabel)
        .accessibilityValue(controller.hasPlayed ? Text("Played") : Text(""))
        .accessibilityHint(controller.error ?? "")
        .contextMenu {
            if isActive, url != nil {
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
            }
        }
        .accessibilityActions {
            if isActive, url != nil {
                ForEach(VoicePlaybackSession.speeds, id: \.self) { speed in
                    Button("Set playback speed to \(speed.formatted())×") {
                        session.setSpeed(speed)
                    }
                }
            }
        }
    }

    private var waveform: some View {
        VoiceWaveformScrubber(
            controller: controller, isEnabled: isActive && url != nil,
            color: accent, height: metrics.waveformHeight
        )
    }

    private var playbackLabel: Text {
        if url == nil { return Text("Audio unavailable") }
        if controller.wantsPlayback { return Text("Cancel audio loading") }
        if controller.error != nil { return Text("Retry audio playback") }
        return controller.isPlaying ? Text("Pause voice message") : Text("Play voice message")
    }

    private var status: String {
        if url == nil { return AppLanguage.localized("Audio unavailable") }
        if !isActive && controller.duration <= 0 { return AppLanguage.localized("Voice message") }
        if controller.isLoading || controller.duration <= 0 && controller.error == nil {
            return AppLanguage.localized("Loading audio…")
        }
        if controller.error != nil { return AppLanguage.localized("Unable to play audio") }
        return
            "\(voicePlaybackTime(controller.position)) / \(voicePlaybackTime(controller.duration))"
    }
}
