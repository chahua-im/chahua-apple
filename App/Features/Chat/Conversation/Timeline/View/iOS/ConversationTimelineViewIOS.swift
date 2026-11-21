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
                    TimelineViewportNavigationControls(
                        model: model, viewport: model.viewport, badgeColor: unreadBadgeColor
                    )
                    .padding(ChahuaTheme.Spacing.large)
                    .padding(.bottom, chatComposerInset)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ChahuaTheme.conversationBackground(for: colorScheme))
            .modifier(TimelineSelectionRangeOverlay(range: model.selectionRange, actions: actions))
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
                    .overlay {
                        if model.rows.isEmpty, model.state.content == .ready {
                            let title: LocalizedStringKey = model.state.history == .notDownloaded
                                ? "No messages downloaded" : "No messages yet"
                            Text(title)
                                .foregroundStyle(ChahuaTheme.secondaryText)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .top) {
                        VStack(spacing: 0) {
                            initialHistoryBanner
                            historyStatusBanner
                            if model.state.missingOfflineMessage != nil {
                                failureBanner("Message not available offline")
                            } else if let failure = model.state.repositionFailure {
                                failureBanner(failure == .liveEdge
                                    ? "Couldn’t load messages." : "That message isn’t available.")
                            }
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
            } else if model.state.content == .initialLoadFailed {
                VStack(spacing: ChahuaTheme.Spacing.small) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Couldn’t load messages").font(.headline)
                    Text("Check your connection and try again.").foregroundStyle(
                        ChahuaTheme.secondaryText)
                    Button("Try again") { Task { await model.retryInitial() } }
                }
            } else {
                TimelineInitialLoadingView(model: model)
            }
        }

        @ViewBuilder
        private var historyStatusBanner: some View {
            if model.state.suppressesSeedHistoryStatus {
                EmptyView()
            } else if model.state.historyConnection == .offline {
                statusBanner(model.state.history == .notDownloaded && !model.rows.isEmpty
                    ? "Offline · No messages downloaded" : "Offline", retry: true)
            } else if model.state.historyConnection == .refreshing {
                statusBanner("Reconnecting…", loading: true)
            } else if model.state.reconciliationFailed {
                statusBanner("Couldn’t refresh messages.", retry: true)
            } else if let connectionMessage {
                statusBanner(connectionMessage, loading: true)
            } else if model.state.history == .saved || model.state.history == .verifiedEmpty {
                statusBanner("Saved messages", retry: true)
            }
        }

        private func statusBanner(
            _ title: LocalizedStringKey, loading: Bool = false, retry: Bool = false
        ) -> some View {
            HStack(spacing: ChahuaTheme.Spacing.small) {
                if loading { ProgressView().controlSize(.small) }
                Text(title).foregroundStyle(ChahuaTheme.secondaryText)
                Spacer()
                if retry {
                    Button("Retry") { Task { await model.retryNetworkHistory() } }
                }
            }
            .font(.caption)
            .padding(ChahuaTheme.Spacing.small)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.small))
            .padding(.horizontal)
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
            switch model.state.olderEdgePresentation {
            case .none:
                EmptyView()
            case .loading:
                ProgressView().controlSize(.small).padding()
            case .retryOlder:
                Button("Couldn’t load older messages — Retry") { model.retryOlder() }.padding()
            case .retryNetworkHistory:
                Button("Couldn’t refresh messages — Retry") {
                    Task { await model.retryNetworkHistory() }
                }.padding()
            case .saved(let saved):
                let title: LocalizedStringKey =
                    saved == .section ? "Older saved section" : "Load older saved messages"
                Button(title) {
                    model.browseSavedEdge(.older)
                }
                .buttonStyle(.bordered)
                .background(.regularMaterial, in: Capsule())
                .padding()
            }
        }

        @ViewBuilder
        private var newerEdgeOverlay: some View {
            if model.state.newer == .loading {
                ProgressView().controlSize(.small).padding()
            } else if model.state.newer == .failed {
                Button("Couldn’t load newer messages — Retry") { model.retryNewer() }.padding()
            } else if let saved = model.state.newerSaved {
                let title: LocalizedStringKey =
                    saved == .section ? "Newer saved section" : "Load newer saved messages"
                Button(title) {
                    model.browseSavedEdge(.newer)
                }
                .buttonStyle(.bordered)
                .background(.regularMaterial, in: Capsule())
                .padding()
            }
        }

        private func failureBanner(_ title: LocalizedStringKey) -> some View {
            HStack {
                Text(title)
                Spacer()
                Button("Dismiss") { model.dismissRepositionFailure() }
            }
            .font(.caption).padding(ChahuaTheme.Spacing.small).background(
                .regularMaterial, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.small)
            ).padding()
        }

    }

    /// Only navigation chrome observes scroll-time presentation. Keeping this a real
    /// child prevents viewport changes from rebuilding the timeline host or composer.
    private struct TimelineViewportNavigationControls: View {
        @ObservedObject var model: ConversationTimelineModel
        @ObservedObject var viewport: TimelineViewportPresentation
        let badgeColor: ConversationUnreadBadgeColor

        var body: some View {
            TimelineNavigationControls(
                showsJumpToLatest: viewport.value.showsJumpToLatest,
                unreadMessageCount: model.jumpUnreadCount,
                unreadMentionCount: model.unreadMentionJumpCount,
                unreadReactionCount: model.unreadReactionJumpCount,
                isBusy: model.activityJumpInProgress || isRepositioning,
                badgeColor: badgeColor,
                jumpToLatest: { Task { await model.jumpTowardLatest() } },
                jumpToMention: { Task { await model.jumpToNextMention() } },
                jumpToReaction: { Task { await model.jumpToNextReaction() } }
            )
        }

        private var isRepositioning: Bool {
            if case .repositioning = model.state.content { return true }
            return false
        }
    }

#endif
