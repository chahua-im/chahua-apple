import SwiftUI

/// Playback and compose previews deliberately share one tap/drag contract.
struct VoiceWaveformScrubber: View {
    @ObservedObject var controller: VoicePlaybackController
    let isEnabled: Bool
    let color: Color
    var height: CGFloat = 32
    @GestureState private var seekPreview: TimeInterval?

    private var canInteract: Bool {
        isEnabled && !controller.isLoading && controller.error == nil && controller.duration > 0
    }
    private var position: TimeInterval {
        min(max(0, seekPreview ?? controller.position), max(0, controller.duration))
    }

    var body: some View {
        GeometryReader { geometry in
            VoiceWaveformShape(
                samples: controller.waveform,
                progress: controller.duration > 0 ? position / controller.duration : 0,
                accent: color, waveformHeight: height
            )
            .contentShape(Rectangle())
            // A recognized drag excludes the tap, including its release. A touch
            // below the threshold toggles playback without changing the position.
            .gesture(
                DragGesture(minimumDistance: 8)
                    .updating($seekPreview) { value, preview, _ in
                        guard canInteract else { return }
                        preview = seekPosition(x: value.location.x, width: geometry.size.width)
                    }
                    .onEnded { value in
                        guard canInteract else { return }
                        controller.seek(to: seekPosition(x: value.location.x, width: geometry.size.width))
                    }
                    .exclusively(before: TapGesture().onEnded {
                        guard canInteract else { return }
                        controller.toggle()
                    })
            )
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Voice message position"))
        .accessibilityValue(Text("\(time(position)) of \(time(controller.duration))"))
        .accessibilityAction {
            guard canInteract else { return }
            controller.toggle()
        }
        .accessibilityAdjustableAction { direction in
            guard canInteract else { return }
            switch direction {
            case .increment: controller.seek(to: min(controller.duration, controller.position + 5))
            case .decrement: controller.seek(to: max(0, controller.position - 5))
            @unknown default: break
            }
        }
        .accessibilityHidden(!canInteract)
        .allowsHitTesting(canInteract)
    }

    private func seekPosition(x: CGFloat, width: CGFloat) -> TimeInterval {
        min(1, max(0, x / max(1, width))) * controller.duration
    }

    private func time(_ time: TimeInterval) -> String {
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
            // Density follows display width, not the stored envelope's sample
            // count. Resample below so wide iPad previews never become sparse.
            let count = max(1, Int(size.width / 5))
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
