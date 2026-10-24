#if os(iOS)
    import ChahuaAPI
    import SwiftUI
    import UIKit

    /// Owns the single active menu outside recycled native rows. Message identity is
    /// retained and actions resolve against the live timeline, not the captured row.
    struct MessageInteractionHost<Content: View>: View {
        @ObservedObject var model: ConversationTimelineModel
        var context: MessageInteractionContext
        var actions: TimelineBubbleActions
        @ViewBuilder var content: (TimelineBubbleActions) -> Content
        @Environment(\.mediaContext) private var mediaContext
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.locale) private var locale
        @Environment(\.timeZone) private var timeZone
        @Environment(\.layoutDirection) private var layoutDirection
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.scenePhase) private var scenePhase
        @State private var target: Target?
        private var isSelectingMessages: Bool { actions.isSelectingMessages }

        private struct Target {
            let key: ConversationMessageStableKey
            let source: MessageInteractionSource
        }

        private var selectedRow: TimelineMessageRow? {
            guard let target else { return nil }
            for row in model.rows {
                if case .message(let message) = row, message.entry.stableKey == target.key {
                    return message
                }
            }
            return nil
        }

        private var routedActions: TimelineBubbleActions {
            var result = actions
            result.interactionContext = context
            result.openContextMenu =
                target == nil && !isSelectingMessages
                ? { row, source in
                    guard !isSelectingMessages, !context.isReadOnly,
                        row.entry.messageType != .system
                    else { return }
                    target = Target(key: row.entry.stableKey, source: source)
                } : nil
            if isSelectingMessages || !context.canWrite { result.toggleReaction = nil }
            if isSelectingMessages { result.openReactionDetails = nil }
            if isSelectingMessages || target != nil || !context.canWrite {
                result.replyToMessage = nil
            }
            return result
        }

        private func toggleMessageSelection(_ message: MessageResponse) {
            target = nil
            actions.toggleMessageSelection?(message)
        }

        var body: some View {
            content(routedActions)
                .background {
                    MessageInteractionWindowPresenter(
                        isPresented: target != nil && selectedRow != nil,
                        reduceMotion: reduceMotion,
                        pressFeedback: target?.source.pressFeedback,
                        onClose: { target = nil },
                        overlay: { animation in
                            AnyView(
                                overlay(animation: animation)
                                    .environment(\.colorScheme, colorScheme)
                                    .environment(\.locale, locale)
                                    .environment(\.timeZone, timeZone)
                                    .environment(\.layoutDirection, layoutDirection)
                                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                            )
                        })
                }
                .onChange(of: model.rows) { _, _ in
                    if target != nil && selectedRow == nil { target = nil }
                }
                .onChange(of: ObjectIdentifier(model)) { _, _ in
                    // A replacement conversation/thread/account must not inherit selection.
                    target = nil
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { target = nil }
                }
                .onDisappear {
                    target = nil
                }
        }

        @ViewBuilder
        private func overlay(animation: MessageInteractionAnimation) -> some View {
            if let target, let row = selectedRow {
                MessageInteractionOverlay(
                    row: row, context: actions.pinContext(for: row, base: context),
                    currentUserID: model.currentUserID,
                    source: target.source, reduceMotion: reduceMotion,
                    mediaContext: mediaContext, actions: actions,
                    animation: animation,
                    onBlock: { pending in
                        guard pending.body.messageType == .text, pending.forwardRequest == nil
                        else { return }
                        self.target = nil
                        actions.blockPendingMessage?(pending)
                    },
                    onRevoke: { pending in
                        self.target = nil
                        actions.revokePendingMessage?(pending)
                    },
                    isReacting: actions.isReacting(to: row.entry),
                    onReaction: { emoji in
                        guard !isSelectingMessages, let liveRow = selectedRow,
                            MessageActionPolicy(row: liveRow, context: context).canReact
                        else { return }
                        actions.toggleReaction?(liveRow, emoji)
                    },
                    onAction: { action in
                        guard !isSelectingMessages, let liveRow = selectedRow,
                            MessageActionPolicy(
                                row: liveRow,
                                context: actions.pinContext(for: liveRow, base: context)
                            ).availability(of: action) == .enabled
                        else { return }
                        if action == .select, let message = liveRow.entry.remoteMessage {
                            toggleMessageSelection(message)
                        } else if action == .forward, let message = liveRow.entry.remoteMessage {
                            self.target = nil
                            actions.forwardMessage?(message)
                        } else if action == .reply, let message = liveRow.entry.remoteMessage,
                            let reply = actions.replyToMessage
                        {
                            self.target = nil
                            reply(message)
                        } else if action == .edit, let message = liveRow.entry.remoteMessage,
                            let edit = actions.editMessage
                        {
                            self.target = nil
                            edit(message)
                        } else if action == .pin || action == .unpin,
                            let message = liveRow.entry.remoteMessage,
                            let togglePin = actions.togglePin
                        {
                            self.target = nil
                            togglePin(message)
                        } else if action == .delete, let message = liveRow.entry.remoteMessage,
                            let delete = actions.deleteMessage
                        {
                            self.target = nil
                            delete(message)
                        } else if action == .thread, let message = liveRow.entry.remoteMessage,
                            let openThread = actions.openThread
                        {
                            self.target = nil
                            openThread(message.id)
                        } else if action == .reactionDetails,
                            let message = liveRow.entry.remoteMessage,
                            let openDetails = actions.openReactionDetails
                        {
                            self.target = nil
                            openDetails(message)
                        } else if action == .copy, let text = liveRow.entry.text {
                            UIPasteboard.general.string = text
                            self.target = nil
                        }
                    },
                    onClose: { self.target = nil }
                )
            }
        }
    }

    private struct MessageInteractionOverlay: View {
        let row: TimelineMessageRow
        let context: MessageInteractionContext
        let currentUserID: Int32
        let source: MessageInteractionSource
        let reduceMotion: Bool
        let mediaContext: AppMediaContext?
        let actions: TimelineBubbleActions
        @ObservedObject var animation: MessageInteractionAnimation
        let onBlock: (PendingOutgoingMessage) -> Void
        let onRevoke: (PendingOutgoingMessage) -> Void
        let isReacting: Bool
        let onReaction: (String) -> Void
        let onAction: (MessageMenuAction) -> Void
        let onClose: () -> Void
        @State private var reactionHeight: CGFloat = 52
        @State private var actionsHeight: CGFloat = 126
        @State private var previewCache = TimelineLayoutCache()
        @State private var showsEmojiKeyboard = false
        @State private var isEmojiPopoverPresented = false

        // Idiom, not size class: even a narrow iPad Split View keeps the picker
        // attached to the smiley, while iPhone retains its bottom-docked surface.
        private var usesEmojiPopover: Bool { UIDevice.current.userInterfaceIdiom == .pad }

        var body: some View {
            GeometryReader { geometry in
                let presentation =
                    source.presentation.row == .message(row)
                    ? source.presentation
                    : TimelineRowPresentation.make(
                        row: .message(row), currentUserID: currentUserID,
                        isThreadTimeline: context.isThreadView,
                        environment: source.presentation.environment)
                let layout =
                    presentation.layoutKey == source.presentation.layoutKey
                    ? source.layout
                    : previewCache.layout(
                        for: presentation, environment: source.presentation.environment)
                let bubbleSize = layout.frames[.bubble]?.size ?? source.rect.size
                let insets = animation.safeAreaInsets
                let keyboardHeight = min(300, max(160, geometry.size.height * 0.42))
                let keyboardBottomPadding = max(16, insets.bottom)
                let availableHeight = max(1, geometry.size.height - insets.top - insets.bottom)
                let popoverSize = CGSize(
                    width: min(360, max(1, geometry.size.width - insets.left - insets.right - 32)),
                    height: min(
                        360, max(160, availableHeight - min(bubbleSize.height, 120) - 140)))
                // Leave space above the anchor for the native popover, without
                // measuring its presentation back into the overlay's layout.
                let popoverTopSpace =
                    showsEmojiKeyboard && usesEmojiPopover ? popoverSize.height + 16 : 0
                let dockHeight =
                    showsEmojiKeyboard && !usesEmojiPopover
                    ? keyboardHeight + max(0, keyboardBottomPadding - insets.bottom) + 12 : 0
                let bounds = CGRect(
                    x: insets.left, y: insets.top + popoverTopSpace,
                    width: max(1, geometry.size.width - insets.left - insets.right),
                    height: max(
                        1,
                        availableHeight - popoverTopSpace - dockHeight))
                let controlsWidth = min(276, max(1, bounds.width - 32))
                let policy = MessageActionPolicy(row: row, context: context)
                let placement = MessageOverlayLayout(
                    bounds: bounds, source: source.rect, previewSize: bubbleSize,
                    controlsWidth: controlsWidth,
                    reactionHeight: policy.canReact
                        ? (showsEmojiKeyboard ? 76 : reactionHeight) : 0,
                    actionsHeight: showsEmojiKeyboard ? 0 : actionsHeight,
                    isOutgoing: row.isOutgoing)
                let previewFrame = placement.previewFrame
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(0.24))
                        .opacity(animation.isPresented ? 1 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onClose)
                        .accessibilityLabel(
                            showsEmojiKeyboard ? "Dismiss emoji picker" : "Dismiss message actions"
                        )
                        .accessibilityAddTraits(.isButton)
                    TimelineRowRepresentable(
                        presentation: presentation, layout: layout,
                        context: .init(
                            currentUserID: currentUserID, isThreadTimeline: context.isThreadView,
                            isInteractionPreview: true),
                        actions: actions, mediaContext: mediaContext
                    )
                    // The inner native view keeps every original text/media rectangle.
                    // Only its outer viewport is clipped when the screen is too small.
                    .frame(width: bubbleSize.width, height: bubbleSize.height)
                    .frame(
                        width: previewFrame.width, height: previewFrame.height,
                        alignment: row.isOutgoing ? .topTrailing : .topLeading
                    )
                    .clipShape(Rectangle().inset(by: -8))
                    .shadow(
                        color: .black.opacity(animation.isPresented ? 0.24 : 0), radius: 18, y: 10
                    )
                    .scaleEffect(reduceMotion ? 1 : animation.previewScale)
                    .opacity(Double(animation.previewOpacity))
                    .position(
                        x: reduceMotion || animation.isPresented
                            ? previewFrame.midX
                            : source.rect.midX + (row.isOutgoing ? 1 : -1)
                                * (bubbleSize.width - previewFrame.width) * animation.previewScale
                                / 2,
                        y: reduceMotion || animation.isPresented
                            ? previewFrame.midY
                            : source.rect.minY + previewFrame.height / 2
                                + (bubbleSize.height - previewFrame.height)
                                * (1 - animation.previewScale) / 2
                    )
                    // Touchable so its text can be selected; row gestures, links and media
                    // are inert in interaction previews.
                    .allowsHitTesting(animation.isPresented)
                    .accessibilityHidden(true)
                    if policy.canReact {
                        if showsEmojiKeyboard {
                            ReactionPickerPlaceholder(onClose: onClose)
                                .frame(width: 76, height: 76)
                                .popover(
                                    isPresented: emojiPopoverPresentation,
                                    attachmentAnchor: .rect(.bounds),
                                    arrowEdge: .bottom
                                ) {
                                    emojiKeyboard(policy: policy)
                                        .frame(width: popoverSize.width, height: popoverSize.height)
                                        .presentationCompactAdaptation(.popover)
                                }
                                .task {
                                    // Present only after the new anchor is mounted. A
                                    // false binding write before this is not a dismissal.
                                    if usesEmojiPopover && showsEmojiKeyboard {
                                        isEmojiPopoverPresented = true
                                    }
                                }
                                .position(
                                    x: min(
                                        bounds.maxX - 38,
                                        max(bounds.minX + 38, previewFrame.maxX - 38)),
                                    y: placement.reactionFrame.midY)
                        } else {
                            menu(.reactions, width: controlsWidth)
                                .fixedSize(horizontal: false, vertical: true)
                                .background {
                                    GeometryReader { size in
                                        Color.clear.onAppear { reactionHeight = size.size.height }
                                            .onChange(of: size.size.height) { _, height in
                                                reactionHeight = height
                                            }
                                    }
                                }
                                .frame(
                                    width: placement.reactionFrame.width,
                                    height: placement.reactionFrame.height
                                )
                                .clipped()
                                .modifier(
                                    MessageMenuTransition(
                                        animation: animation, reduceMotion: reduceMotion)
                                )
                                .position(
                                    x: placement.reactionFrame.midX, y: placement.reactionFrame.midY
                                )
                        }
                    }
                    if !showsEmojiKeyboard {
                        ScrollView {
                            VStack(spacing: 8) {
                                menu(.actions, width: controlsWidth)
                                if case .pending(let pending) = row.entry, !pending.dispatchClaimed,
                                    actions.modifiablePendingMessageIDs.contains(
                                        pending.clientGeneratedID)
                                {
                                    VStack(spacing: 0) {
                                        Button(
                                            "Move back to composer",
                                            systemImage: "square.and.pencil"
                                        ) { onBlock(pending) }
                                        .disabled(
                                            actions.blockPendingMessage == nil
                                                || pending.body.messageType != .text
                                        )
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        Divider()
                                        Button(
                                            "Revoke unsent message", systemImage: "trash",
                                            role: .destructive
                                        ) { onRevoke(pending) }
                                        .disabled(actions.revokePendingMessage == nil)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                    .font(.callout)
                                    .buttonStyle(.plain)
                                    .background(
                                        .regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                                }
                            }
                            .frame(width: controlsWidth)
                            .fixedSize(horizontal: false, vertical: true)
                            .background {
                                GeometryReader { size in
                                    Color.clear.onAppear { actionsHeight = size.size.height }
                                        .onChange(of: size.size.height) { _, height in
                                            actionsHeight = height
                                        }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(
                            width: placement.actionsFrame.width,
                            height: placement.actionsFrame.height
                        )
                        .modifier(
                            MessageMenuTransition(animation: animation, reduceMotion: reduceMotion)
                        )
                        .position(x: placement.actionsFrame.midX, y: placement.actionsFrame.midY)
                    }
                    if showsEmojiKeyboard && policy.canReact && !usesEmojiPopover {
                        emojiKeyboard(policy: policy)
                            .frame(height: keyboardHeight)
                            // The shared grid already supplies its 16pt inset.
                            .padding(.leading, insets.left)
                            .padding(.trailing, insets.right)
                            .padding(.bottom, keyboardBottomPadding)
                            .frame(width: geometry.size.width)
                            .background(.regularMaterial)
                            .clipShape(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 24, topTrailingRadius: 24)
                            )
                            .position(
                                x: geometry.size.width / 2,
                                y: geometry.size.height - (keyboardHeight + keyboardBottomPadding)
                                    / 2
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onChange(of: policy.canReact) { _, canReact in
                    if showsEmojiKeyboard && !canReact { onClose() }
                }
                .onChange(of: actions.toggleReaction == nil) { _, unavailable in
                    if showsEmojiKeyboard && unavailable { onClose() }
                }
            }
            .ignoresSafeArea()
        }

        private var emojiPopoverPresentation: Binding<Bool> {
            Binding(
                get: { usesEmojiPopover && showsEmojiKeyboard && isEmojiPopoverPresented },
                set: { presented in
                    guard isEmojiPopoverPresented != presented else { return }
                    isEmojiPopoverPresented = presented
                    // Native outside-tap/Escape dismissal ends the whole interaction;
                    // never return to the old actions or quick reaction strip.
                    if !presented && showsEmojiKeyboard { onClose() }
                })
        }

        private func emojiKeyboard(policy: MessageActionPolicy) -> some View {
            ReactionEmojiKeyboard(
                eligibility: .init(
                    canReact: policy.canReact && actions.toggleReaction != nil,
                    isReacting: isReacting,
                    reactions: row.entry.remoteMessage?.reactions ?? []),
                onSelect: { emoji in
                    onReaction(emoji)
                    onClose()
                })
        }

        private func menu(_ section: MessageActionMenu.Section, width: CGFloat) -> some View {
            MessageActionMenu(
                row: row, context: context, isReacting: isReacting,
                onReaction: onReaction, onAction: onAction, onClose: onClose,
                onMoreReactions: {
                    guard actions.toggleReaction != nil, !isReacting else { return }
                    withAnimation(
                        reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.25)
                    ) {
                        showsEmojiKeyboard = true
                    }
                },
                controlsWidth: width, section: section)
        }
    }

    private struct MessageMenuTransition: ViewModifier {
        @ObservedObject var animation: MessageInteractionAnimation
        let reduceMotion: Bool

        func body(content: Content) -> some View {
            content
                .opacity(animation.isPresented ? 1 : 0)
                .scaleEffect(reduceMotion || animation.isPresented ? 1 : 0.92)
                .offset(y: reduceMotion || animation.isPresented ? 0 : 10)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                .allowsHitTesting(animation.isPresented)
        }
    }
#endif
