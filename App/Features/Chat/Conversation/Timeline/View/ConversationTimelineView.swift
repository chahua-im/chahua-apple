import SwiftUI

struct ConversationTimelineView: View {
    @ObservedObject var model: ConversationTimelineModel
    var initialPosition: TimelineInitialPosition = .liveEdge

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
        .task { await model.loadInitial(position: initialPosition) }
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
            TimelineHostView(model: model)
                .overlay(alignment: .top) { olderEdgeOverlay }
                .overlay(alignment: .bottom) { newerEdgeOverlay }
                .overlay { if case .repositioning = model.state.content { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.medium)) } }
                .overlay(alignment: .top) { if let failure = model.state.repositionFailure { failureBanner(failure) } }
        }
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

    private var canJumpToLiveEdge: Bool { !model.rows.isEmpty && !(model.isAtLiveEdge && model.state.live.followsLatest) }
}

#if os(iOS)
import UIKit
struct TimelineHostView: UIViewControllerRepresentable {
    let model: ConversationTimelineModel
    func makeUIViewController(context: Context) -> TimelineCollectionViewController { TimelineCollectionViewController(model: model) }
    func updateUIViewController(_ controller: TimelineCollectionViewController, context: Context) {}
}
#elseif os(macOS)
import AppKit
struct TimelineHostView: NSViewControllerRepresentable {
    let model: ConversationTimelineModel
    func makeNSViewController(context: Context) -> TimelineTableViewController { TimelineTableViewController(model: model) }
    func updateNSViewController(_ controller: TimelineTableViewController, context: Context) {}
}
#endif
