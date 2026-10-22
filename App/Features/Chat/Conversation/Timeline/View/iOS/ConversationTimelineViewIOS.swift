#if os(iOS)
    import SwiftUI

    struct ConversationTimelineView: View {
        @ObservedObject var model: ConversationTimelineModel
        @Environment(\.mediaContext) private var mediaContext
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.chatHeaderInset) private var chatHeaderInset
        @Environment(\.chatComposerInset) private var chatComposerInset
        @AppStorage(ConversationListPreferences.unreadBadgeColorStorageKey)
        private var unreadBadgeColorRawValue = ConversationListPreferences.defaultUnreadBadgeColor
            .rawValue
        var initialPosition: TimelineInitialPosition = .liveEdge
        var loadsInitialAutomatically = true
        var actions = TimelineBubbleActions()

        private var unreadBadgeColor: ConversationUnreadBadgeColor {
            ConversationUnreadBadgeColor(rawValue: unreadBadgeColorRawValue)
                ?? ConversationListPreferences.defaultUnreadBadgeColor
        }

        var body: some View {
            // A scrolling viewport fills its proposal; its message contents must not
            // participate in the enclosing window's intrinsic/minimum-size probes.
            GeometryReader { geometry in
                ZStack(alignment: .bottomTrailing) {
                    // Fill the viewport in every state: the loading/failure placeholders
                    // are intrinsically small, and the header backdrop overlay would
                    // otherwise be laid out inside the placeholder's frame.
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .overlay { headerBackdrop }
                    TimelineNavigationControls(
                        showsJumpToLatest: model.showsJumpToLatest,
                        unreadMessageCount: model.jumpUnreadCount,
                        unreadMentionCount: model.unreadMentionJumpCount,
                        unreadReactionCount: model.unreadReactionJumpCount,
                        isBusy: model.activityJumpInProgress || isRepositioning,
                        badgeColor: unreadBadgeColor,
                        jumpToLatest: { Task { await model.jumpTowardLatest() } },
                        jumpToMention: { Task { await model.jumpToNextMention() } },
                        jumpToReaction: { Task { await model.jumpToNextReaction() } }
                    )
                    .padding(ChahuaTheme.Spacing.large)
                    .padding(.bottom, chatComposerInset)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ChahuaTheme.conversationBackground(for: colorScheme))
            .task {
                if loadsInitialAutomatically { await model.loadInitial(position: initialPosition) }
            }
        }

        /// Blurs rows scrolling under the floating chrome: the header, and the pinned
        /// bar when present, since `chatHeaderInset` covers both. Drawn here so it sits
        /// above the rows but below that chrome; it starts at the screen top.
        @ViewBuilder
        private var headerBackdrop: some View {
            if chatHeaderInset > 0 {
                VStack(spacing: 0) {
                    ChatHeaderBackdrop(edge: .top, strength: .strong)
                        .frame(height: chatHeaderInset + 24)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(.container, edges: .top)
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
                    .overlay {
                        if isRepositioning {
                            ProgressView().padding().background(
                                .regularMaterial,
                                in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.medium))
                        }
                    }
                    .overlay(alignment: .top) {
                        if let failure = model.state.repositionFailure {
                            failureBanner(failure).padding(.top, chatHeaderInset)
                        }
                    }
                    .overlay(alignment: .top) {
                        if let connectionMessage {
                            HStack(spacing: ChahuaTheme.Spacing.small) {
                                ProgressView().controlSize(.small)
                                Text(connectionMessage)
                                    .foregroundStyle(ChahuaTheme.secondaryText)
                                Spacer()
                            }
                            .font(.caption).padding(ChahuaTheme.Spacing.small)
                            .background(
                                .regularMaterial,
                                in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.small)
                            ).padding()
                            .padding(.top, chatHeaderInset)
                        } else if model.state.reconciliationFailed {
                            HStack {
                                Text("Couldn’t refresh messages.")
                                Spacer()
                                Button("Retry") { Task { await model.reconcileAfterReconnect() } }
                            }
                            .font(.caption).padding(ChahuaTheme.Spacing.small)
                            .background(
                                .regularMaterial,
                                in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.small)
                            ).padding()
                            .padding(.top, chatHeaderInset)
                        }
                    }
            } else if model.state.content == .initialLoadFailed {
                VStack(spacing: ChahuaTheme.Spacing.small) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Couldn’t load messages").font(.headline)
                    Text("Check your connection and try again.").foregroundStyle(
                        ChahuaTheme.secondaryText)
                    Button("Try again") { Task { await model.retryInitial() } }
                }
            } else {
                ProgressView("Loading messages")
            }
        }

        private var connectionMessage: LocalizedStringKey? {
            switch model.state.realtimeStatus {
            case .idle, .connected: nil
            case .connecting: "Connecting…"
            case .reconnecting: "Reconnecting…"
            case .unavailable: "Can’t connect right now. Retrying…"
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
            if model.state.older == .loading {
                ProgressView().controlSize(.small).padding()
            } else if model.state.older == .failed {
                Button("Couldn’t load older messages — Retry") { model.retryOlder() }.padding()
            }
        }

        @ViewBuilder
        private var newerEdgeOverlay: some View {
            if model.state.newer == .loading {
                ProgressView().controlSize(.small).padding()
            } else if model.state.newer == .failed {
                Button("Couldn’t load newer messages — Retry") { model.retryNewer() }.padding()
            }
        }

        private func failureBanner(_ target: ConversationTimelineState.RepositionTarget)
            -> some View
        {
            HStack {
                Text(
                    target == .liveEdge
                        ? "Couldn’t load messages." : "That message isn’t available.")
                Spacer()
                Button("Dismiss") { model.dismissRepositionFailure() }
            }
            .font(.caption).padding(ChahuaTheme.Spacing.small).background(
                .regularMaterial, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.small)
            ).padding()
        }

    }

#endif
