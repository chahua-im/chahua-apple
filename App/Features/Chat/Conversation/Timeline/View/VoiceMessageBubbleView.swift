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
    @State private var retry = 0

    private struct LoadKey: Hashable {
        let url: URL?
        let active: Bool
        let retry: Int
    }

    private var accent: Color { isOutgoing ? .white : .accentColor }
    private var canPlay: Bool { isActive && url != nil && !controller.isLoading && controller.error == nil && controller.duration > 0 }

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
                Text(status)
                    .font(.system(size: metrics.captionSize))
                    .monospacedDigit()
                    .foregroundStyle(accent.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: metrics.statusWidth(for: geometry.size.width), height: metrics.statusHeight, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityHidden(canPlay)
            }
            .frame(width: geometry.size.width, height: metrics.height(for: geometry.size.width), alignment: .top)
        }
        .clipped()
        .allowsHitTesting(isActive)
        .accessibilityElement(children: .contain)
        .environment(\.locale, Locale(identifier: localeIdentifier))
        .environment(\.layoutDirection, layoutDirection)
        .task(id: LoadKey(url: url, active: isActive, retry: retry)) {
            guard isActive, let url else { return }
            await controller.load(url: url)
        }
        .onDisappear {
            controller.stop()
        }
    }

    private var playbackButton: some View {
        Button {
            if controller.error != nil || controller.duration <= 0 {
                retry += 1
            } else {
                controller.toggle()
            }
        } label: {
            ZStack {
                Circle().fill(accent.opacity(isOutgoing ? 0.14 : 0.11))
                if controller.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                } else {
                    Image(systemName: url == nil ? "exclamationmark" : controller.error != nil ? "arrow.clockwise" : controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: metrics.bodySize, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: metrics.circleSize, height: metrics.circleSize)
            .frame(width: metrics.targetSize, height: metrics.targetSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isActive || url == nil || controller.isLoading)
        .accessibilityLabel(playbackLabel)
        .accessibilityHint(controller.error ?? "")
    }

    private var waveform: some View {
        VoiceWaveformScrubber(
            controller: controller, isEnabled: isActive && url != nil,
            color: accent, height: metrics.waveformHeight
        )
    }

    private var playbackLabel: Text {
        if url == nil { return Text("Audio unavailable") }
        if controller.isLoading { return Text("Loading audio…") }
        if controller.error != nil { return Text("Retry audio playback") }
        return controller.isPlaying ? Text("Pause voice message") : Text("Play voice message")
    }

    private var status: String {
        if url == nil { return String(localized: "Audio unavailable") }
        if !isActive && controller.duration <= 0 { return String(localized: "Voice message") }
        if controller.isLoading || controller.duration <= 0 && controller.error == nil { return String(localized: "Loading audio…") }
        if controller.error != nil { return String(localized: "Unable to play audio") }
        return "\(Self.time(controller.position)) / \(Self.time(controller.duration))"
    }


    private static func time(_ time: TimeInterval) -> String {
        let seconds = time.isFinite ? max(0, Int(time)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

