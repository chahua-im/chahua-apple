import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Shared delivery indicator used by production timeline hosts and the tuning workshop.
struct MessageDeliveryStatusView: View {
    enum Status: String, CaseIterable, Identifiable {
        case queued = "Queued"
        case sending = "Sending"
        case sent = "Sent"
        case read = "Read"
        case failed = "Failed to send"

        var id: Self { self }
    }

    nonisolated static let defaultCheckSeparation: CGFloat = 0.3

    nonisolated static func layoutSize(
        for size: CGFloat, checkSeparation: CGFloat = defaultCheckSeparation
    ) -> CGSize {
        CGSize(width: size * (1 + checkSeparation), height: size)
    }

    let status: Status
    var size: CGFloat = 12
    var weight: Font.Weight = .regular
    var spinnerStroke: CGFloat = 1.2
    var checkSeparation: CGFloat = Self.defaultCheckSeparation
    var checkHeight: CGFloat?
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
                DeliveryCheckmark(isRead: status == .read, separation: checkSeparation)
                    .stroke(
                        style: StrokeStyle(
                            lineWidth: checkStroke, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: checkSize * (1 + checkSeparation), height: checkSize)
                    .offset(y: checkSize * (0.5 - DeliveryCheckmark.verticalCenter))
                    .frame(width: layoutSize.width, height: layoutSize.height, alignment: .leading)
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: size, weight: weight))
        .frame(width: size, height: size)
        // Reserve the read state's width for every state so the timestamp never shifts.
        .frame(width: layoutSize.width, height: layoutSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(status.rawValue)))
    }

    private var layoutSize: CGSize {
        Self.layoutSize(for: size, checkSeparation: checkSeparation)
    }

    private var checkSize: CGFloat {
        guard let checkHeight else { return size }
        return checkHeight / (DeliveryCheckmark.verticalSpan + checkStrokeRatio)
    }

    private var checkStroke: CGFloat { checkSize * checkStrokeRatio }

    private var checkStrokeRatio: CGFloat {
        switch weight {
        case .medium: 0.12
        case .semibold: 0.14
        default: 0.1
        }
    }
}

/// Native timeline hosts supply the measured slot; only the shared SwiftUI indicator is hosted.
struct MessageDeliveryStatusContent: View {
    let status: MessageDeliveryStatusView.Status
    let size: CGFloat
    let foreground: Color
    var isVisible = true
    var checkSeparation: CGFloat = MessageDeliveryStatusView.defaultCheckSeparation
    var checkHeight: CGFloat?

    var body: some View {
        let nominalSize = MessageDeliveryStatusView.layoutSize(
            for: size, checkSeparation: checkSeparation)
        Group {
            if isVisible {
                GeometryReader { geometry in
                    let scale = min(
                        1,
                        min(
                            geometry.size.width / nominalSize.width,
                            geometry.size.height / nominalSize.height))
                    MessageDeliveryStatusView(
                        status: status, size: size, checkSeparation: checkSeparation,
                        checkHeight: checkHeight
                    )
                    .foregroundStyle(foreground)
                    .fixedSize()
                    .scaleEffect(scale)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
        }
        .frame(idealWidth: nominalSize.width, idealHeight: nominalSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The trailing check has only a short entry stroke, not a second complete checkmark.
/// This keeps the two rising strokes parallel without crossing the leading check.
private struct DeliveryCheckmark: Shape {
    nonisolated static let top: CGFloat = 0.14
    nonisolated static let bottom: CGFloat = 0.82
    nonisolated static var verticalSpan: CGFloat { bottom - top }
    nonisolated static var verticalCenter: CGFloat { (top + bottom) / 2 }

    let isRead: Bool
    let separation: CGFloat

    func path(in rect: CGRect) -> Path {
        let unit = rect.width / (1 + separation)
        let origin = rect.minX
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin + x * unit, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.06, 0.56))
        path.addLine(to: point(0.30, Self.bottom))
        path.addLine(to: point(0.88, Self.top))
        if isRead {
            path.move(to: point(0.22 + separation, 0.73))
            path.addLine(to: point(0.30 + separation, Self.bottom))
            path.addLine(to: point(0.88 + separation, Self.top))
        }
        return path
    }
}

#if DEBUG
    /// Open in Canvas, the component gallery, or launch a Debug build with -message-status-preview.
    struct MessageDeliveryStatusPreview: View {
        @State private var size = Double(MessageMetadata.defaultFontSize)
        @State private var spinnerStroke: Double = 1.2
        @State private var checkSeparation: Double = MessageDeliveryStatusView
            .defaultCheckSeparation
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
                    Text(verbatim: "Shared with production message indicators")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        tuningSlider("Timestamp size", value: $size, range: 9...20)
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
            let metadata = MessageMetadata(
                time: "09:41", state: displayState(for: status), isOutgoing: true,
                isRead: status == .read, fontSize: size, checkSeparation: checkSeparation)
            return HStack(alignment: .bottom, spacing: 14) {
                Text(verbatim: text)
                    .padding(.vertical, 8)
                footer(metadata)
                    .padding(.bottom, max(0, 8 - metadata.textBaselineDrop))
            }
            .foregroundStyle(.white)
            .padding(.leading, 12)
            .padding(.trailing, max(0, 12 - metadata.textTrailingOutset))
            .background(.blue, in: RoundedRectangle(cornerRadius: 16))
        }

        private func displayState(
            for status: MessageDeliveryStatusView.Status
        ) -> ConversationMessageDisplayState {
            switch status {
            case .queued: .queued
            case .sending: .sending
            case .sent, .read: .delivered
            case .failed: .failed
            }
        }

        /// Draw the production Core Text timestamp and use its fitted status frame.
        /// Canvas only adapts the native drawing context; it does not remeasure the footer.
        private func footer(_ metadata: MessageMetadata) -> some View {
            let bounds = CGRect(origin: .zero, size: metadata.size)
            let statusFrame = metadata.statusFrame(in: bounds)
            return Canvas { context, _ in
                context.withCGContext { cgContext in
                    #if os(macOS)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(
                            cgContext: cgContext, flipped: true)
                        metadata.draw(in: bounds)
                        NSGraphicsContext.restoreGraphicsState()
                    #else
                        UIGraphicsPushContext(cgContext)
                        metadata.draw(in: bounds)
                        UIGraphicsPopContext()
                    #endif
                }
            }
            .overlay(alignment: .topLeading) {
                if let status = metadata.status {
                    MessageDeliveryStatusView(
                        status: status, size: metadata.statusFontSize, weight: weight.fontWeight,
                        spinnerStroke: spinnerStroke, checkSeparation: checkSeparation,
                        checkHeight: metadata.digitHeight
                    )
                    .foregroundStyle(Color(metadata.foreground))
                    .position(x: statusFrame.midX, y: statusFrame.midY)
                }
            }
            .frame(width: bounds.width, height: bounds.height)
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
