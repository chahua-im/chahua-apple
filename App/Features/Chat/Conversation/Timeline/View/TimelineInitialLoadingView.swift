import SwiftUI

/// Observes coarse loading state only; viewport updates stay in the native timeline.
struct TimelineInitialLoadingView: View {
    @ObservedObject var model: ConversationTimelineModel
    @Environment(\.conversationDisplayValues) private var displayValues
    @Environment(\.chatHeaderInset) private var headerInset
    @Environment(\.chatComposerInset) private var composerInset

    var body: some View {
        if model.rows.isEmpty,
            model.state.content == .idle || model.state.content == .loadingInitial
        {
            TimelineMessageSkeleton(
                showsMessageDetails: model.isGroupChat || displayValues.showDmDetails,
                showAllAvatars: displayValues.showAllAvatars
            )
            .padding(.top, headerInset)
            .padding(.bottom, composerInset)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading messages")
        }
    }
}

struct TimelineMessageSkeleton: View {
    var showsMessageDetails: Bool
    var showAllAvatars: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isWideChatLayout) private var isWideChatLayout
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption) private var authorSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36
    @State private var pulse = false

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = isWideChatLayout ? 24 : TimelineRowMetrics.rowHorizontalInset
            let lane = showsMessageDetails ? avatarSize + TimelineRowMetrics.laneGap : 0
            let availableWidth = max(0, geometry.size.width - 2 * (inset + lane))
            VStack(spacing: 0) {
                // Match the PWA: two received messages, then one sent message, twice.
                ForEach(0..<6) { index in
                    row(index, availableWidth: availableWidth)
                        .padding(.top, index % 3 == 1 ? 2 : 4)
                        .padding(.bottom, 2)
                }
            }
            .padding(.horizontal, inset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .clipped()
        .onAppear { pulse = true }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
            value: pulse)
    }

    private var pulseOpacity: Double { reduceMotion || !pulse ? 1 : 0.55 }

    private func row(_ index: Int, availableWidth: CGFloat) -> some View {
        let outgoing = index % 3 == 2
        let last = index % 3 != 0 || showAllAvatars
        let width = min(bodySize * (index.isMultiple(of: 2) ? 7 : 12), availableWidth)
        return HStack(alignment: .bottom, spacing: TimelineRowMetrics.laneGap) {
            if outgoing { Spacer(minLength: 0) }
            if showsMessageDetails && !outgoing { avatar(visible: last) }
            VStack(alignment: .leading, spacing: 0) {
                if index % 3 != 1 && showsMessageDetails {
                    line(size: authorSize)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, max(0, width - 24) * 0.4)
                        .padding(.bottom, 2)
                }
                line(size: bodySize)
                if index % 3 == 0 { line(size: bodySize) }
            }
            .padding(.horizontal, TimelineRowMetrics.textHorizontalInset)
            .padding(.vertical, TimelineRowMetrics.textVerticalInset)
            .frame(width: width)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: !outgoing ? (last ? 0 : 8) : 16,
                    bottomTrailingRadius: outgoing ? (last ? 0 : 8) : 16,
                    topTrailingRadius: 16,
                    style: .circular
                )
                .fill(ChahuaTheme.secondaryBackground)
            }
            .background(alignment: outgoing ? .bottomTrailing : .bottomLeading) {
                if last {
                    TimelineSkeletonTail()
                        .fill(ChahuaTheme.secondaryBackground)
                        .frame(width: 8, height: 17)
                        .scaleEffect(x: outgoing ? -1 : 1, y: 1)
                        .offset(x: outgoing ? 8 : -8)
                }
            }
            if showsMessageDetails && outgoing { avatar(visible: last) }
            if !outgoing { Spacer(minLength: 0) }
        }
    }

    private func avatar(visible: Bool) -> some View {
        Circle()
            .fill(ChahuaTheme.secondaryBackground)
            .frame(width: avatarSize, height: avatarSize)
            .opacity(visible ? pulseOpacity : 0)
    }

    private func line(size: CGFloat) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.12))
            .frame(height: size * 0.65)
            .frame(height: size * 1.3)
            .opacity(pulseOpacity)
    }
}

private struct TimelineSkeletonTail: Shape {
    func path(in rect: CGRect) -> Path {
        // PWA droplet, in its 8 × 17 point coordinate space.
        var path = Path()
        path.move(to: CGPoint(x: 1, y: 17))
        path.addLine(to: CGPoint(x: 8, y: 17))
        path.addLine(to: CGPoint(x: 8, y: 0))
        path.addCurve(
            to: CGPoint(x: 5.9, y: 8.8), control1: CGPoint(x: 7.8, y: 2.84),
            control2: CGPoint(x: 7.1, y: 5.8))
        path.addCurve(
            to: CGPoint(x: 1.3, y: 15.3), control1: CGPoint(x: 5, y: 11.1),
            control2: CGPoint(x: 3.5, y: 13.3))
        path.addQuadCurve(to: CGPoint(x: 1, y: 17), control: CGPoint(x: 0, y: 16.5))
        path.closeSubpath()
        return path
    }
}
