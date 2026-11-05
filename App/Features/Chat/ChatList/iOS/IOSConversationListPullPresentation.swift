#if os(iOS)
    import SwiftUI

    // Compact iOS uses the prototype's fixed search slot and progressive spokes.
    // SwiftUI's refreshable indicator cannot express this two-stage presentation;
    // the native scroll driver supplies the opening without a second layout inset.
    struct IOSConversationListPullSearchPresentation<Content: View, Feedback: View>: View {
        let pullDistance: CGFloat
        let searchHeight: CGFloat
        @ViewBuilder let content: () -> Content
        @ViewBuilder let feedback: () -> Feedback

        private var progress: CGFloat {
            min(1, max(0, (pullDistance - 8) / 48))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                content()
                    .frame(height: 40)
                    .opacity(Double(progress))
                    .scaleEffect(0.9 + 0.1 * progress, anchor: .top)
                    .offset(y: -10 * (1 - progress))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .frame(
                        height: ConversationListScrollScope.prototypeDrawerHeight, alignment: .top)
                feedback()
            }
            .frame(height: min(searchHeight, max(0, pullDistance)), alignment: .top)
            .clipped()
            .accessibilityHidden(pullDistance < ConversationListScrollScope.prototypeDrawerHeight)
        }
    }

    struct IOSConversationListPullRefreshIndicator: View {
        let pullDistance: CGFloat
        let isRefreshing: Bool
        let searchHeight: CGFloat

        private var effectivePullDistance: CGFloat {
            pullDistance - (searchHeight - ConversationListScrollScope.prototypeDrawerHeight)
        }

        private var progress: CGFloat {
            min(1, max(0, (effectivePullDistance - 60) / 60))
        }

        private var isArmed: Bool {
            effectivePullDistance >= ConversationListScrollScope.prototypeRefreshDistance
        }

        private var visibleSpokes: Int {
            min(8, max(0, Int(floor((effectivePullDistance - 60) / 60 * 8)) + 1))
        }

        var body: some View {
            ZStack(alignment: .top) {
                Color.clear
                spinner
                    .frame(width: 28, height: 28)
                    .scaleEffect(isRefreshing || isArmed ? 1 : 0.8 + 0.2 * progress)
                    .opacity(
                        isRefreshing
                            ? 1 : Double(min(1, max(0, (effectivePullDistance - 60) / 16)))
                    )
                    .offset(y: searchHeight + max(0, pullDistance - searchHeight) / 2 - 14)
            }
            .frame(height: max(0, pullDistance), alignment: .top)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }

        @ViewBuilder
        private var spinner: some View {
            if isRefreshing {
                TimelineView(.animation(minimumInterval: 0.08)) { context in
                    spokes(step: Int(floor(context.date.timeIntervalSinceReferenceDate / 0.08)) % 8)
                }
            } else {
                spokes(step: 0)
            }
        }

        private func spokes(step: Int) -> some View {
            Canvas { context, size in
                var rotated = context
                rotated.translateBy(x: size.width / 2, y: size.height / 2)
                var spoke = Path()
                spoke.move(to: CGPoint(x: 0, y: -11))
                spoke.addLine(to: CGPoint(x: 0, y: -5.5))
                for index in 0..<8 {
                    let opacity =
                        isRefreshing
                        ? 0.22 + 0.78 * Double((index - step + 8) % 8) / 7
                        : (index < visibleSpokes ? (isArmed ? 1.0 : 0.85) : 0.15)
                    rotated.stroke(
                        spoke,
                        with: .color(
                            Color(.sRGB, red: 124 / 255, green: 124 / 255, blue: 128 / 255)
                                .opacity(opacity)),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    rotated.rotate(by: .degrees(45))
                }
            }
        }
    }
#endif
