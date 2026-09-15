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

    private struct Target {
        let key: ConversationMessageStableKey
        let source: MessageInteractionSource
    }

    private var selectedRow: TimelineMessageRow? {
        guard let target else { return nil }
        for row in model.rows {
            if case .message(let message) = row, message.entry.stableKey == target.key { return message }
        }
        return nil
    }

    private var routedActions: TimelineBubbleActions {
        var result = actions
        result.interactionContext = context
        result.openContextMenu = target == nil ? { row, source in
            guard row.entry.messageType != .system else { return }
            target = Target(key: row.entry.stableKey, source: source)
        } : nil
        if !context.canWrite { result.toggleReaction = nil }
        if target != nil || !context.canWrite { result.replyToMessage = nil }
        return result
    }

    var body: some View {
        content(routedActions)
            .background {
                MessageInteractionWindowPresenter(
                    isPresented: target != nil && selectedRow != nil,
                    reduceMotion: reduceMotion,
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
            .onChange(of: model.rows) { _ in
                if target != nil && selectedRow == nil { target = nil }
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active { target = nil }
            }
            .onDisappear { target = nil }
    }

    @ViewBuilder
    private func overlay(animation: MessageInteractionAnimation) -> some View {
        if let target, let row = selectedRow {
            MessageInteractionOverlay(
                row: row, context: context, currentUserID: model.currentUserID,
                source: target.source, reduceMotion: reduceMotion,
                mediaContext: mediaContext, actions: actions,
                animation: animation,
                onBlock: { pending in
                    self.target = nil
                    actions.blockPendingMessage?(pending)
                },
                onRevoke: { pending in
                    self.target = nil
                    actions.revokePendingMessage?(pending)
                },
                isReacting: actions.pendingReactionMessageIDs.contains(row.entry.serverID ?? ""),
                onReaction: { emoji in
                    guard let liveRow = selectedRow,
                        MessageActionPolicy(row: liveRow, context: context).canReact else { return }
                    actions.toggleReaction?(liveRow, emoji)
                },
                onAction: { action in
                    guard let liveRow = selectedRow,
                        MessageActionPolicy(row: liveRow, context: context).availability(of: action) == .enabled
                    else { return }
                    if action == .reply, let message = liveRow.entry.remoteMessage,
                        let reply = actions.replyToMessage {
                        self.target = nil
                        reply(message)
                    } else if action == .edit, let message = liveRow.entry.remoteMessage,
                        let edit = actions.editMessage {
                        self.target = nil
                        edit(message)
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

    var body: some View {
        GeometryReader { geometry in
            let presentation = source.presentation.row == .message(row) ? source.presentation
                : TimelineRowPresentation.make(
                    row: .message(row), currentUserProfile: actions.currentUserProfile,
                    currentUserID: currentUserID, isThreadTimeline: context.isThreadView,
                    environment: source.presentation.environment)
            let layout = presentation.layoutKey == source.presentation.layoutKey ? source.layout
                : previewCache.layout(for: presentation, environment: source.presentation.environment)
            let bubbleSize = layout.frames[.bubble]?.size ?? source.rect.size
            let insets = animation.safeAreaInsets
            let bounds = CGRect(
                x: insets.left, y: insets.top,
                width: max(1, geometry.size.width - insets.left - insets.right),
                height: max(1, geometry.size.height - insets.top - insets.bottom))
            let controlsWidth = min(276, max(1, bounds.width - 32))
            let policy = MessageActionPolicy(row: row, context: context)
            let placement = MessageOverlayLayout(
                bounds: bounds, source: source.rect, previewSize: bubbleSize,
                controlsWidth: controlsWidth,
                reactionHeight: policy.canReact ? reactionHeight : 0,
                actionsHeight: actionsHeight, isOutgoing: row.isOutgoing)
            let previewFrame = placement.previewFrame
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.24))
                    .opacity(animation.isPresented ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityLabel("Dismiss message actions")
                    .accessibilityAddTraits(.isButton)
                TimelineRowRepresentable(
                    presentation: presentation, layout: layout,
                    context: .init(currentUserID: currentUserID, isThreadTimeline: context.isThreadView, isInteractionPreview: true),
                    actions: actions, mediaContext: mediaContext)
                    // The inner native view keeps every original text/media rectangle.
                    // Only its outer viewport is clipped when the screen is too small.
                    .frame(width: bubbleSize.width, height: bubbleSize.height)
                    .frame(width: previewFrame.width, height: previewFrame.height,
                           alignment: row.isOutgoing ? .topTrailing : .topLeading)
                    .clipShape(Rectangle().inset(by: -8))
                    .shadow(color: .black.opacity(animation.isPresented ? 0.24 : 0), radius: 18, y: 10)
                    .scaleEffect(reduceMotion ? 1 : animation.isLifted ? 1.035 : 1)
                    .opacity(reduceMotion && !animation.isPresented ? 0 : 1)
                    .position(
                        x: reduceMotion || animation.isPresented ? previewFrame.midX : source.rect.midX,
                        y: reduceMotion || animation.isPresented ? previewFrame.midY : source.rect.minY + previewFrame.height / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if policy.canReact {
                    menu(.reactions, width: controlsWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { size in
                                Color.clear.onAppear { reactionHeight = size.size.height }
                                    .onChange(of: size.size.height) { reactionHeight = $0 }
                            }
                        }
                        .frame(width: placement.reactionFrame.width, height: placement.reactionFrame.height)
                        .clipped()
                        .modifier(MessageMenuTransition(animation: animation, reduceMotion: reduceMotion))
                        .position(x: placement.reactionFrame.midX, y: placement.reactionFrame.midY)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        menu(.actions, width: controlsWidth)
                        if case .pending(let pending) = row.entry, !pending.dispatchClaimed,
                           actions.modifiablePendingMessageIDs.contains(pending.clientGeneratedID) {
                            VStack(spacing: 0) {
                                Button("Move back to composer", systemImage: "square.and.pencil") { onBlock(pending) }
                                    .disabled(actions.blockPendingMessage == nil)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                Divider()
                                Button("Revoke unsent message", systemImage: "trash", role: .destructive) { onRevoke(pending) }
                                    .disabled(actions.revokePendingMessage == nil)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .font(.callout)
                            .buttonStyle(.plain)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .frame(width: controlsWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { size in
                            Color.clear.onAppear { actionsHeight = size.size.height }
                                .onChange(of: size.size.height) { actionsHeight = $0 }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(width: placement.actionsFrame.width, height: placement.actionsFrame.height)
                .modifier(MessageMenuTransition(animation: animation, reduceMotion: reduceMotion))
                .position(x: placement.actionsFrame.midX, y: placement.actionsFrame.midY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }

    private func menu(_ section: MessageActionMenu.Section, width: CGFloat) -> some View {
        MessageActionMenu(
            row: row, context: context, isReacting: isReacting,
            onReaction: onReaction, onAction: onAction, onClose: onClose,
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
