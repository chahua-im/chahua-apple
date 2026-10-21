import SwiftUI

/// Visual proposal for message delivery states. The native timeline still uses MessageMetadata.
struct MessageDeliveryStatusView: View {
    enum Status: String, CaseIterable, Identifiable {
        case queued = "Queued"
        case sending = "Sending"
        case sent = "Sent"
        case read = "Read"
        case failed = "Failed to send"

        var id: Self { self }
    }

    let status: Status
    var size: CGFloat = 12
    var weight: Font.Weight = .regular
    var spinnerStroke: CGFloat = 1.2
    var checkSeparation: CGFloat = 0.3
    @State private var spinning = false

    var body: some View {
        Group {
            switch status {
            case .queued:
                Image(systemName: "clock")
            case .sending:
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(style: StrokeStyle(lineWidth: spinnerStroke, lineCap: .round))
                    .padding(spinnerStroke / 2)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear { spinning = true }
                    .onDisappear { spinning = false }
                    .animation(
                        .linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            case .sent, .read:
                ZStack {
                    Image(systemName: "checkmark")
                        .offset(x: status == .read ? -size * checkSeparation / 2 : 0)
                    if status == .read {
                        Image(systemName: "checkmark")
                            .offset(x: size * checkSeparation / 2)
                    }
                }
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: size, weight: weight))
        .frame(width: size, height: size)
        // Reserve the read state's width for every state so the timestamp never shifts.
        .frame(width: size * (1 + checkSeparation), height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(status.rawValue)))
    }
}

#if DEBUG
    /// Open in Canvas, the component gallery, or launch a Debug build with -message-status-preview.
    struct MessageDeliveryStatusPreview: View {
        @State private var size: Double = 12
        @State private var spinnerStroke: Double = 1.2
        @State private var checkSeparation: Double = 0.3
        @State private var weight: PreviewWeight = .regular
        @State private var selected: MessageDeliveryStatusView.Status = .sending
        @State private var playback: Task<Void, Never>?

        private enum PreviewWeight: String, CaseIterable, Identifiable {
            case regular, medium, semibold
            var id: Self { self }
            var fontWeight: Font.Weight {
                switch self {
                case .regular: .regular
                case .medium: .medium
                case .semibold: .semibold
                }
            }
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(verbatim: "Message status workshop")
                        .font(.title2.bold())
                    Text(verbatim: "Visual proposal · native timeline unchanged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        tuningSlider("Icon size", value: $size, range: 9...20)
                        tuningSlider("Spinner stroke", value: $spinnerStroke, range: 0.8...2.5)
                        tuningSlider("Check separation", value: $checkSeparation, range: 0.3...0.7)
                        Picker(selection: $weight) {
                            ForEach(PreviewWeight.allCases) { weight in
                                Text(verbatim: weight.rawValue.capitalized).tag(weight)
                            }
                        } label: {
                            Text(verbatim: "Symbol weight")
                        }
                        .pickerStyle(.segmented)
                    }
                    HStack {
                        Picker(selection: $selected) {
                            ForEach(MessageDeliveryStatusView.Status.allCases) { status in
                                Text(verbatim: status.rawValue).tag(status)
                            }
                        } label: {
                            Text(verbatim: "State")
                        }
                        .disabled(playback != nil)
                        Button {
                            playDelivery()
                        } label: {
                            Label {
                                Text(verbatim: "Play")
                            } icon: {
                                Image(systemName: "play.fill")
                            }
                        }
                        .disabled(playback != nil)
                    }
                    bubble(status: selected, text: "Watch the delivery transition")
                    Divider()
                    ForEach(MessageDeliveryStatusView.Status.allCases) { status in
                        HStack {
                            Text(verbatim: status.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .leading)
                            Spacer(minLength: 8)
                            bubble(status: status, text: "Hello")
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 320, minHeight: 540)
            .onDisappear {
                playback?.cancel()
                playback = nil
            }
        }

        private func bubble(status: MessageDeliveryStatusView.Status, text: String) -> some View {
            HStack(alignment: .bottom, spacing: 16) {
                Text(verbatim: text)
                HStack(spacing: 4) {
                    Text(verbatim: "09:41")
                        .font(.system(size: size).monospacedDigit())
                    MessageDeliveryStatusView(
                        status: status, size: size, weight: weight.fontWeight,
                        spinnerStroke: spinnerStroke, checkSeparation: checkSeparation)
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.blue, in: RoundedRectangle(cornerRadius: 16))
        }

        private func tuningSlider(
            _ title: String, value: Binding<Double>, range: ClosedRange<Double>
        ) -> some View {
            HStack {
                Text(verbatim: title).frame(width: 120, alignment: .leading)
                Slider(value: value, in: range)
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1))))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            .font(.caption)
        }

        private func playDelivery() {
            playback = Task { @MainActor in
                defer { playback = nil }
                for status in [MessageDeliveryStatusView.Status.queued, .sending, .sent, .read] {
                    guard !Task.isCancelled else { return }
                    selected = status
                    do { try await Task.sleep(for: .seconds(status == .sending ? 2 : 1)) } catch {
                        return
                    }
                }
            }
        }
    }

    #Preview("Message status · Light") {
        MessageDeliveryStatusPreview().preferredColorScheme(.light)
    }

    #Preview("Message status · Dark") {
        MessageDeliveryStatusPreview().preferredColorScheme(.dark)
    }
#endif
