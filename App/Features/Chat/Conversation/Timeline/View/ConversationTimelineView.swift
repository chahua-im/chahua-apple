import SwiftUI

struct ConversationTimelineView: View {
    @ObservedObject var model: ConversationTimelineModel
    @Environment(\.mediaContext) private var mediaContext
    @Environment(\.colorScheme) private var colorScheme
    var initialPosition: TimelineInitialPosition = .liveEdge
    var loadsInitialAutomatically = true
    var actions = TimelineBubbleActions()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            if canJumpToLiveEdge {
                Button { Task { await model.jumpToLiveEdge() } } label: {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .padding(12)
                        .background(.regularMaterial, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if model.state.live.unseenCount > 0 {
                                Text("\(model.state.live.unseenCount)").font(.caption2.bold()).padding(5).foregroundStyle(.white).background(ChahuaTheme.accent, in: Capsule()).offset(x: 8, y: -8)
                            }
                        }
                }
                .accessibilityLabel("Jump to latest messages")
                .padding(ChahuaTheme.Spacing.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChahuaTheme.conversationBackground(for: colorScheme))
        .task { if loadsInitialAutomatically { await model.loadInitial(position: initialPosition) } }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state.content {
        case .idle, .loadingInitial:
            ProgressView("Loading messages")
        case .initialLoadFailed:
            VStack(spacing: ChahuaTheme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("Couldn’t load messages").font(.headline)
                Text("Check your connection and try again.").foregroundStyle(ChahuaTheme.secondaryText)
                Button("Try again") { Task { await model.retryInitial() } }
            }
        case .ready, .repositioning:
            timelineHost
                .overlay(alignment: .top) { olderEdgeOverlay }
                .overlay(alignment: .bottom) { newerEdgeOverlay }
                .overlay { if case .repositioning = model.state.content { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.medium)) } }
                .overlay(alignment: .top) { if let failure = model.state.repositionFailure { failureBanner(failure) } }
                .overlay(alignment: .top) {
                    if model.state.reconciliationFailed {
                        HStack {
                            Text("Couldn’t refresh messages.")
                            Spacer()
                            Button("Retry") { Task { await model.reconcileAfterReconnect() } }
                        }
                        .font(.caption).padding(ChahuaTheme.Spacing.small)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.small)).padding()
                    }
                }

        }
    }
    @ViewBuilder
    private var timelineHost: some View {
        #if os(macOS)
        TimelineHostView(model: model, actions: actions, mediaContext: mediaContext)
        #else
        TimelineHostView(model: model, mediaContext: mediaContext)
        #endif
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

    private var canJumpToLiveEdge: Bool {
        model.state.content == .ready && !(model.isAtLiveEdge && model.state.live.followsLatest)
    }
}

#if os(iOS)
import UIKit
struct TimelineHostView: UIViewControllerRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let model: ConversationTimelineModel
    var mediaContext: AppMediaContext?

    func makeUIViewController(context: Context) -> TimelineCollectionViewController {
        let controller = TimelineCollectionViewController(model: model)
        controller.mediaContext = mediaContext
        controller.colorScheme = colorScheme
        return controller
    }

    func updateUIViewController(_ controller: TimelineCollectionViewController, context: Context) {
        controller.mediaContext = mediaContext
        controller.colorScheme = colorScheme
    }
}
#elseif os(macOS)
import AppKit
struct TimelineHostView: NSViewControllerRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let model: ConversationTimelineModel
    var actions = TimelineBubbleActions()
    var mediaContext: AppMediaContext?

    func makeNSViewController(context: Context) -> TimelineTableViewController {
        let controller = TimelineTableViewController(model: model, actions: actions)
        controller.mediaContext = mediaContext
        controller.colorScheme = colorScheme
        return controller
    }

    func updateNSViewController(_ controller: TimelineTableViewController, context: Context) {
        controller.mediaContext = mediaContext
        controller.actions = actions
        controller.colorScheme = colorScheme
    }
}
#endif
