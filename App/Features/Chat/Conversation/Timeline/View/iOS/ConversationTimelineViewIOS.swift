#if os(iOS)
import SwiftUI

struct ConversationTimelineView: View {
    @ObservedObject var model: ConversationTimelineModel
    @Environment(\.mediaContext) private var mediaContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatHeaderInset) private var chatHeaderInset
    @Environment(\.chatComposerInset) private var chatComposerInset
    @ScaledMetric(relativeTo: .caption2) private var jumpBadgeDiameter: CGFloat = 22
    var initialPosition: TimelineInitialPosition = .liveEdge
    var loadsInitialAutomatically = true
    var actions = TimelineBubbleActions()

    var body: some View {
        // A scrolling viewport fills its proposal; its message contents must not
        // participate in the enclosing window's intrinsic/minimum-size probes.
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                content
                    .clipped()
                if model.showsJumpToLatest {
                    Button { Task { await model.jumpTowardLatest() } } label: {
                        jumpToLatestSymbol
                            .overlay(alignment: .topTrailing) {
                                if model.jumpUnreadCount > 0 {
                                    Text("\(model.jumpUnreadCount)")
                                        .font(.caption2.bold())
                                        .lineLimit(1)
                                        .fixedSize()
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: jumpBadgeDiameter, minHeight: jumpBadgeDiameter)
                                        .foregroundStyle(.white)
                                        .background(ChahuaTheme.accent, in: Capsule())
                                        .offset(x: 8, y: -8)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to latest messages")
                    .accessibilityValue(model.jumpUnreadCount > 0 ? String(localized: "\(model.jumpUnreadCount) unread messages") : "")
                    .padding(ChahuaTheme.Spacing.large)
                    .padding(.bottom, chatComposerInset)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChahuaTheme.conversationBackground(for: colorScheme))
        .task { if loadsInitialAutomatically { await model.loadInitial(position: initialPosition) } }
    }

    @ViewBuilder
    private var jumpToLatestSymbol: some View {
        let symbol = Image(systemName: "chevron.down")
            .font(.headline)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        if #available(macOS 26, iOS 26, *) {
            symbol.glassEffect(.regular.interactive(), in: Circle())
        } else {
            symbol.background(.regularMaterial, in: Circle())
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.rows.isEmpty || model.state.content == .ready || isRepositioning {
            timelineHost
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        initialHistoryBanner
                        olderEdgeOverlay
                    }
                    .padding(.top, chatHeaderInset)
                }
                .overlay(alignment: .bottom) {
                    newerEdgeOverlay.padding(.bottom, chatComposerInset)
                }
                .overlay { if isRepositioning { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.medium)) } }
                .overlay(alignment: .top) {
                    if let failure = model.state.repositionFailure {
                        failureBanner(failure).padding(.top, chatHeaderInset)
                    }
                }
                .overlay(alignment: .top) {
                    if model.state.reconciliationFailed {
                        HStack {
                            Text("Couldn’t refresh messages.")
                            Spacer()
                            Button("Retry") { Task { await model.reconcileAfterReconnect() } }
                        }
                        .font(.caption).padding(ChahuaTheme.Spacing.small)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.small)).padding()
                        .padding(.top, chatHeaderInset)
                    }
                }
        } else if model.state.content == .initialLoadFailed {
            VStack(spacing: ChahuaTheme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("Couldn’t load messages").font(.headline)
                Text("Check your connection and try again.").foregroundStyle(ChahuaTheme.secondaryText)
                Button("Try again") { Task { await model.retryInitial() } }
            }
        } else {
            ProgressView("Loading messages")
        }
    }

    private var isRepositioning: Bool {
        if case .repositioning = model.state.content { return true }
        return false
    }

    @ViewBuilder
    private var initialHistoryBanner: some View {
        if model.state.content == .idle || model.state.content == .loadingInitial {
            ProgressView("Loading messages")
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(ChahuaTheme.Spacing.small)
                .background(.regularMaterial)
        } else if model.state.content == .initialLoadFailed {
            HStack {
                Text("Couldn’t load messages.")
                Spacer()
                Button("Try again") { Task { await model.retryInitial() } }
            }
            .font(.caption)
            .padding(ChahuaTheme.Spacing.small)
            .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private var timelineHost: some View {
        TimelineHostView(model: model, actions: actions, mediaContext: mediaContext)
    }


    @ViewBuilder
    private var olderEdgeOverlay: some View {
        if model.state.older == .loading { ProgressView().controlSize(.small).padding() }
        else if model.state.older == .failed { Button("Couldn’t load older messages — Retry") { model.retryOlder() }.padding() }
    }

    @ViewBuilder
    private var newerEdgeOverlay: some View {
        if model.state.newer == .loading { ProgressView().controlSize(.small).padding() }
        else if model.state.newer == .failed { Button("Couldn’t load newer messages — Retry") { model.retryNewer() }.padding() }
    }

    private func failureBanner(_ target: ConversationTimelineState.RepositionTarget) -> some View {
        HStack {
            Text(target == .liveEdge ? "Couldn’t load messages." : "That message isn’t available.")
            Spacer()
            Button("Dismiss") { model.dismissRepositionFailure() }
        }
        .font(.caption).padding(ChahuaTheme.Spacing.small).background(.regularMaterial, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.small)).padding()
    }

}


#endif
