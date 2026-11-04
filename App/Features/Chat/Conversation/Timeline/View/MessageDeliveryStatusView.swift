import QuartzCore
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Shared delivery indicator for timeline hosts, conversation lists and the tuning workshop.
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
                    .offset(y: checkSize * (0.5 - MessageDeliveryStatusGeometry.verticalCenter))
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
        return checkHeight / (MessageDeliveryStatusGeometry.verticalSpan + checkStrokeRatio)
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

/// Canonical, downward-positive check geometry, shared by SwiftUI outside the
/// timeline and the native timeline renderer. The trailing check has only a short
/// entry stroke, keeping the two rising strokes parallel without crossing.
enum MessageDeliveryStatusGeometry {
    nonisolated static let top: CGFloat = 0.14
    nonisolated static let bottom: CGFloat = 0.82
    nonisolated static var verticalSpan: CGFloat { bottom - top }
    nonisolated static var verticalCenter: CGFloat { (top + bottom) / 2 }

    nonisolated static func checkPath(in rect: CGRect, isRead: Bool, separation: CGFloat) -> CGPath
    {
        let unit = rect.width / (1 + separation)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * rect.height)
        }
        let path = CGMutablePath()
        path.move(to: point(0.06, 0.56))
        path.addLine(to: point(0.30, bottom))
        path.addLine(to: point(0.88, top))
        if isRead {
            path.move(to: point(0.22 + separation, 0.73))
            path.addLine(to: point(0.30 + separation, bottom))
            path.addLine(to: point(0.88 + separation, top))
        }
        return path
    }
}

/// Immutable drawing inputs, not a hosted view. Paths are prepared when metadata
/// changes; fitted bounds only transform them, including during scrolling/reuse.
struct MessageDeliveryStatusContent: Equatable {
    let status: MessageDeliveryStatusView.Status
    let size: CGFloat
    let foreground: BubbleNativeColor
    let checkSeparation: CGFloat
    let checkHeight: CGFloat?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.status == rhs.status && lhs.size == rhs.size && lhs.foreground == rhs.foreground
            && lhs.checkSeparation == rhs.checkSeparation && lhs.checkHeight == rhs.checkHeight
    }

    var nominalSize: CGSize {
        MessageDeliveryStatusView.layoutSize(for: size, checkSeparation: checkSeparation)
    }

    var strokeWidth: CGFloat {
        status == .sending ? 1.2 : checkSize * 0.1
    }

    private var checkSize: CGFloat {
        checkHeight.map { $0 / (MessageDeliveryStatusGeometry.verticalSpan + 0.1) } ?? size
    }

    func fittedScale(in bounds: CGRect) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0,
            bounds.width.isFinite, bounds.height.isFinite,
            nominalSize.width > 0, nominalSize.height > 0
        else { return 0 }
        return min(1, bounds.width / nominalSize.width, bounds.height / nominalSize.height)
    }

    func makePath() -> CGPath? {
        switch status {
        case .sent, .read:
            return MessageDeliveryStatusGeometry.checkPath(
                in: CGRect(
                    x: 0, y: size / 2 - checkSize * MessageDeliveryStatusGeometry.verticalCenter,
                    width: checkSize * (1 + checkSeparation), height: checkSize),
                isRead: status == .read, separation: checkSeparation)
        case .sending:
            let path = CGMutablePath()
            path.addArc(
                center: CGPoint(x: nominalSize.width / 2, y: size / 2),
                radius: (size - strokeWidth) / 2,
                startAngle: 0, endAngle: .pi * 2 * 0.72, clockwise: false)
            return path
        case .queued, .failed:
            return nil
        }
    }

    func makeSymbol() -> MessageDeliveryStatusSymbol? {
        let name: String
        switch status {
        case .queued: name = "clock"
        case .failed: name = "exclamationmark.circle"
        default: return nil
        }
        #if os(macOS)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        #else
            let image = UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))
        #endif
        return image.map(MessageDeliveryStatusSymbol.init)
    }

    /// The displaying native view supplies the active appearance/trait environment.
    func draw(
        in bounds: CGRect, context: CGContext, path: CGPath?, symbol: MessageDeliveryStatusSymbol?
    ) {
        let scale = fittedScale(in: bounds)
        guard scale > 0, status != .sending else { return }
        context.saveGState()
        context.translateBy(
            x: bounds.midX - nominalSize.width * scale / 2,
            y: bounds.midY - nominalSize.height * scale / 2)
        context.scaleBy(x: scale, y: scale)
        let color: BubbleNativeColor = status == .failed ? .systemRed : foreground
        if let path {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(strokeWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
        } else if let symbol {
            symbol.draw(
                centeredAt: CGPoint(x: nominalSize.width / 2, y: nominalSize.height / 2),
                color: color.cgColor, context: context)
        }
        context.restoreGState()
    }
}

/// Native SF Symbols carry transparent registration padding, which is not the
/// visible glyph's center. Keep the system artwork, but center its actual ink in
/// the fitted slot. The prepared mask is retained until its output scale changes;
/// drawing/scrolling at the same geometry never regenerates or scans a bitmap.
@MainActor
final class MessageDeliveryStatusSymbol {
    private let image: BubbleNativeImage
    #if os(macOS)
        private var raster: CGImage?
        private var rasterScale: CGSize?
        private var canvasSize = CGSize.zero
        private var inkCenter = CGPoint.zero
    #endif

    init(_ image: BubbleNativeImage) {
        self.image = image
    }

    func draw(centeredAt center: CGPoint, color: CGColor, context: CGContext) {
        #if os(macOS)
            let scale = CGSize(
                width: hypot(context.ctm.a, context.ctm.b),
                height: hypot(context.ctm.c, context.ctm.d))
            if rasterScale != scale {
                prepareRaster(scale: scale)
            }
            guard let raster else { return }
            let rect = CGRect(
                x: center.x - inkCenter.x, y: center.y - inkCenter.y,
                width: canvasSize.width, height: canvasSize.height)
        #else
            let rect = CGRect(
                x: center.x - image.size.width / 2, y: center.y - image.size.height / 2,
                width: image.size.width, height: image.size.height)
        #endif
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        #if os(macOS)
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(raster, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        #else
            image.draw(in: rect)
        #endif
        context.setBlendMode(.sourceIn)
        context.setFillColor(color)
        context.fill(rect)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    #if os(macOS)
        private func prepareRaster(scale: CGSize) {
            rasterScale = scale
            raster = nil
            var proposedRect = CGRect(origin: .zero, size: image.size)
            guard
                let source = image.cgImage(
                    forProposedRect: &proposedRect, context: NSGraphicsContext.current, hints: nil),
                let bitmap = CGContext(
                    data: nil, width: source.width, height: source.height,
                    bitsPerComponent: 8, bytesPerRow: source.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let bytes = bitmap.data?.assumingMemoryBound(to: UInt8.self)
            else { return }
            bitmap.draw(
                source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            var minX = source.width
            var minY = source.height
            var maxX = -1
            var maxY = -1
            for y in 0..<source.height {
                for x in 0..<source.width where bytes[y * bitmap.bytesPerRow + x * 4 + 3] != 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return }
            canvasSize = proposedRect.size
            inkCenter = CGPoint(
                x: CGFloat(minX + maxX + 1) / 2 * canvasSize.width / CGFloat(source.width),
                y: CGFloat(minY + maxY + 1) / 2 * canvasSize.height / CGFloat(source.height))
            raster = bitmap.makeImage()
        }
    #endif
}

/// Core Animation owns only the spinner. Static states draw directly in the
/// native view, and leaving the viewport removes the repeating animation entirely.
@MainActor
final class MessageDeliveryStatusSpinner {
    let layer = CAShapeLayer()
    private var isSending = false
    private var isVisible = false
    private var isAnimating = false
    private var content: MessageDeliveryStatusContent?
    private var displayedBounds = CGRect.null

    init() {
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.isHidden = true
    }

    func configure(_ content: MessageDeliveryStatusContent?, path: CGPath?) {
        self.content = content
        isSending = content?.status == .sending
        displayedBounds = .null
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = isSending ? path : nil
        layer.lineWidth = content?.strokeWidth ?? 0
        CATransaction.commit()
        updateAnimation()
    }

    func layout(in bounds: CGRect, color: CGColor?, displayScale: CGFloat) {
        guard let content, isSending else { return }
        guard
            displayedBounds != bounds || layer.strokeColor != color
                || layer.contentsScale != displayScale
        else { return }
        displayedBounds = bounds
        let scale = content.fittedScale(in: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: content.nominalSize)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        layer.strokeColor = color
        layer.contentsScale = displayScale
        CATransaction.commit()
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        updateAnimation()
    }

    private func updateAnimation() {
        let animating = isSending && isVisible
        guard animating != isAnimating else { return }
        isAnimating = animating
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = !animating
        CATransaction.commit()
        if animating {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = Double.pi * 2
            animation.duration = 0.8
            animation.repeatCount = .infinity
            layer.add(animation, forKey: "deliveryRotation")
        } else {
            layer.removeAnimation(forKey: "deliveryRotation")
        }
    }
}

private struct DeliveryCheckmark: Shape {
    let isRead: Bool
    let separation: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            MessageDeliveryStatusGeometry.checkPath(
                in: rect, isRead: isRead, separation: separation))
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
