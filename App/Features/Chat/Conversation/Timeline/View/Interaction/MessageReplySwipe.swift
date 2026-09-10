import SwiftUI

/// Apply to the whole row, with stable message identity supplied by the row host.
struct MessageReplySwipe: ViewModifier {
    var isEnabled: Bool
    var isMeasuring = false
    var onReply: () -> Void

    #if !os(macOS)
        @State private var displacement: CGFloat = 0
        @State private var reachedThreshold = false
        @State private var burst = 0
    #endif

    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
            content
        #else
            content
                .offset(x: isEnabled ? -displacement : 0)
                .clipped()
                .background {
                    if isEnabled {
                        GeometryReader { geometry in
                            MessageReplySwipeArrow(progress: min(displacement / 60, 1), burst: burst)
                                // The PWA's default left swipe exposes the physical right edge,
                                // including when the surrounding text uses right-to-left layout.
                                .position(x: geometry.size.width - 34, y: geometry.size.height / 2)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .background {
                    if !isMeasuring {
                        GeometryReader { _ in
                            MessageRowGestureSource(isEnabled: isEnabled, onChange: update, onFinish: reset, onReply: onReply)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { reset() }
                }
                .onDisappear { reset() }
        #endif
    }

    #if !os(macOS)
        private func update(_ value: CGFloat) {
            withTransaction(Transaction(animation: nil)) {
                displacement = value
                if value >= 60 {
                    if !reachedThreshold { burst += 1 }
                    reachedThreshold = true
                } else {
                    reachedThreshold = false
                }
            }
        }

        private func reset() {
            reachedThreshold = false
            withAnimation(.easeOut(duration: 0.2)) { displacement = 0 }
        }
    #endif
}

#if !os(macOS)

    private struct MessageReplySwipeArrow: View {
        let progress: CGFloat
        let burst: Int

        var body: some View {
            ZStack {
                MessageReplyArrowShape()
                    .stroke(.tint, style: StrokeStyle(lineWidth: 35 * 0.044, lineJoin: .round))
                MessageReplyArrowShape()
                    .fill(.tint)
                    .mask(MessageReplyArrowFill(progress: max(0, 2 * progress - 1)))
            }
            .frame(width: 36, height: 36)
            .opacity(progress)
            .scaleEffect(0.5 + 0.5 * progress)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: burst) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    CubicKeyframe(1.25, duration: 0.18)
                    CubicKeyframe(1, duration: 0.22)
                }
            }
        }
    }

    private struct MessageReplyArrowShape: Shape {
        func path(in rect: CGRect) -> Path {
            // Exact PWA arrowUndoOutline path. Its inner +90° and SVG -90°
            // rotations cancel, leaving this scale and translation in the 36pt box.
            var path = Path()
            path.move(to: CGPoint(x: 240, y: 424))
            path.addLine(to: CGPoint(x: 240, y: 328))
            path.addCurve(
                to: CGPoint(x: 448, y: 424),
                control1: CGPoint(x: 356.4, y: 328),
                control2: CGPoint(x: 399.39, y: 361.76)
            )
            path.addCurve(
                to: CGPoint(x: 240, y: 184),
                control1: CGPoint(x: 448, y: 304.77),
                control2: CGPoint(x: 408.43, y: 184)
            )
            path.addLine(to: CGPoint(x: 240, y: 88))
            path.addLine(to: CGPoint(x: 64, y: 256))
            path.closeSubpath()
            return path.applying(Self.transform(in: rect))
        }

        static func transform(in rect: CGRect) -> CGAffineTransform {
            CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width / 36, y: rect.height / 36)
                .translatedBy(x: 7, y: 6.472)
                .scaledBy(x: 0.044, y: 0.044)
        }
    }

    private struct MessageReplyArrowFill: Shape {
        var progress: CGFloat
        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func path(in rect: CGRect) -> Path {
            // SVG inset() uses the arrow's fill box (64...448, 88...424).
            // For the default left swipe, reveal this same arrow from right to left.
            Path(CGRect(x: 448 - 384 * progress, y: 88, width: 384 * progress, height: 336))
                .applying(MessageReplyArrowShape.transform(in: rect))
        }
    }

#endif
