import SwiftUI

/// Shared by measurement and rendering; audio decoding never participates in row layout.
struct VoiceMessageBubbleMetrics {
    let bodySize: CGFloat
    let captionSize: CGFloat

    // Flutter uses a 32pt circle, 10pt gap and 173pt waveform; the PWA caps its
    // voice content at 280pt. Keep that shape with Apple's 44pt touch target.
    static func preferredWidth(bodySize: CGFloat) -> CGFloat { 280 * max(1, bodySize / 17) }
    var targetSize: CGFloat { max(44, ceil(bodySize * 44 / 17)) }
    var circleSize: CGFloat { max(32, bodySize * 32 / 17) }
    var waveformHeight: CGFloat { max(32, ceil(bodySize * 32 / 17)) }
    var statusHeight: CGFloat { ceil(captionSize * 1.5) }
    func isStacked(width: CGFloat) -> Bool { width < targetSize + 10 + 80 }
    func height(for width: CGFloat) -> CGFloat {
        targetSize + (isStacked(width: width) ? waveformHeight + 6 : 0) + 6 + statusHeight
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
    @State private var seekPreview: TimeInterval?

    private struct LoadKey: Hashable {
        let url: URL?
        let active: Bool
        let retry: Int
    }

    private var accent: Color { isOutgoing ? .white : .accentColor }
    private var canSeek: Bool { isActive && url != nil && !controller.isLoading && controller.error == nil && controller.duration > 0 }
    private var position: TimeInterval { min(max(0, seekPreview ?? controller.position), max(0, controller.duration)) }

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
                    .frame(maxWidth: .infinity, minHeight: metrics.statusHeight, maxHeight: metrics.statusHeight, alignment: .leading)
                    .accessibilityHidden(canSeek)
            }
            .frame(width: geometry.size.width, height: metrics.height(for: geometry.size.width), alignment: .top)
        }
        .clipped()
        .allowsHitTesting(isActive)
        .accessibilityElement(children: .contain)
        .environment(\.locale, Locale(identifier: localeIdentifier))
        .environment(\.layoutDirection, layoutDirection)
        .task(id: LoadKey(url: url, active: isActive, retry: retry)) {
            seekPreview = nil
            guard isActive, let url else { return }
            await controller.load(url: url)
        }
        .onDisappear {
            seekPreview = nil
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
        GeometryReader { geometry in
            VoiceWaveformShape(samples: controller.waveform, progress: controller.duration > 0 ? position / controller.duration : 0, accent: accent, waveformHeight: metrics.waveformHeight)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canSeek else { return }
                        seekPreview = seekPosition(x: value.location.x, width: geometry.size.width)
                    }
                    .onEnded { value in
                        guard canSeek else { seekPreview = nil; return }
                        controller.seek(to: seekPosition(x: value.location.x, width: geometry.size.width))
                        seekPreview = nil
                    })
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Voice message position"))
        .accessibilityValue(Text("\(Self.time(position)) of \(Self.time(controller.duration))"))
        .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            switch direction {
            case .increment: controller.seek(to: min(controller.duration, controller.position + 5))
            case .decrement: controller.seek(to: max(0, controller.position - 5))
            @unknown default: break
            }
        }
        .accessibilityHidden(!canSeek)
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
        return "\(Self.time(position)) / \(Self.time(controller.duration))"
    }

    private func seekPosition(x: CGFloat, width: CGFloat) -> TimeInterval {
        min(1, max(0, x / max(1, width))) * controller.duration
    }

    private static func time(_ time: TimeInterval) -> String {
        let seconds = time.isFinite ? max(0, Int(time)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VoiceWaveformShape: View {
    let samples: [Float]
    let progress: Double
    let accent: Color
    let waveformHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            guard !samples.isEmpty else {
                // No fabricated peaks while loading or when the source is missing.
                let baseline = CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)
                context.fill(Path(roundedRect: baseline, cornerRadius: 1), with: .color(accent.opacity(0.28)))
                return
            }
            let count = min(samples.count, max(1, Int(size.width / 3)))
            let step = size.width / CGFloat(count)
            let barWidth = min(2, step)
            var played = Path()
            var remaining = Path()
            for bar in 0..<count {
                let start = bar * samples.count / count
                let end = max(start + 1, (bar + 1) * samples.count / count)
                var peak: Float = 0
                for index in start..<end where samples[index].isFinite {
                    peak = max(peak, min(1, max(0, samples[index])))
                }
                let height = max(2, CGFloat(peak) * min(waveformHeight, size.height))
                let rect = CGRect(x: CGFloat(bar) * step, y: (size.height - height) / 2, width: barWidth, height: height)
                if Double(bar) / Double(count) < progress {
                    played.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                } else {
                    remaining.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                }
            }
            context.fill(remaining, with: .color(accent.opacity(0.3)))
            context.fill(played, with: .color(accent))
        }
    }
}
