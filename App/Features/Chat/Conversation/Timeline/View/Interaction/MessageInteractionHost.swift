import ChahuaAPI
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Owns the single active menu outside recycled native rows and above the composer.
/// Message identity is retained; content is resolved from the live timeline on every update.
struct MessageInteractionHost<Content: View>: View {
    @ObservedObject var model: ConversationTimelineModel
    var context: MessageInteractionContext
    var actions: TimelineBubbleActions
    @ViewBuilder var content: (TimelineBubbleActions) -> Content
    @Environment(\.mediaContext) private var mediaContext
    @State private var target: Target?

    private struct Target {
        let key: ConversationMessageStableKey
        let source: CGRect
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
        result.openContextMenu =
            target == nil
            ? { row, rect in
                guard row.entry.messageType != .system else { return }
                target = Target(key: row.entry.stableKey, source: rect)
            } : nil
        if !context.canWrite { result.toggleReaction = nil }
        if target != nil || !context.canWrite { result.replyToMessage = nil }
        return result
    }

    var body: some View {
        content(routedActions)
            .overlay {
                if let target, let row = selectedRow {
                    MessageInteractionOverlay(
                        row: row, context: context, currentUserID: model.currentUserID,
                        source: target.source, mediaContext: mediaContext,
                        isReacting: actions.pendingReactionMessageIDs.contains(row.entry.serverID ?? ""),
                        onReaction: { emoji in
                            guard let liveRow = selectedRow,
                                MessageActionPolicy(row: liveRow, context: context).canReact
                            else { return }
                            actions.toggleReaction?(liveRow, emoji)
                        },
                        onAction: { action in
                            if action == .reply, let liveRow = selectedRow,
                                MessageActionPolicy(row: liveRow, context: context).availability(of: action) == .enabled,
                                let message = liveRow.entry.remoteMessage,
                                let reply = actions.replyToMessage
                            {
                                self.target = nil
                                reply(message)
                                return
                            }
                            if action == .copy, let liveRow = selectedRow,
                                MessageActionPolicy(row: liveRow, context: context).availability(of: action)
                                    == .enabled,
                                let text = liveRow.entry.text
                            {
                                #if os(macOS)
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                #else
                                    UIPasteboard.general.string = text
                                #endif
                                self.target = nil
                            }
                        },
                        onClose: { self.target = nil }
                    )
                }
            }
            .onChange(of: model.rows) { _ in
                if target != nil && selectedRow == nil { target = nil }
            }
            .onDisappear { target = nil }
    }
}

private struct MessageInteractionOverlay: View {
    let row: TimelineMessageRow
    let context: MessageInteractionContext
    let currentUserID: Int32
    let source: CGRect
    let mediaContext: AppMediaContext?
    let isReacting: Bool
    let onReaction: (String) -> Void
    let onAction: (MessageMenuAction) -> Void
    let onClose: () -> Void
    @State private var panelSize = CGSize(width: 276, height: 380)

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(1, geometry.size.width - 32)
            let controlsWidth = min(276, availableWidth)
            let previewWidth = min(source.width > 0 ? source.width : controlsWidth, availableWidth)
            let width = max(controlsWidth, previewWidth)
            let origin = geometry.frame(in: .global).origin
            let localSource = source.offsetBy(dx: -origin.x, dy: -origin.y)
            let proposedX = row.isOutgoing ? localSource.maxX - width : localSource.minX
            let x = min(max(16, proposedX), max(16, geometry.size.width - width - 16))
            let proposedY = source == .zero ? (geometry.size.height - panelSize.height) / 2 : localSource.minY - 60
            let y = min(max(12, proposedY), max(12, geometry.size.height - panelSize.height - 12))
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.35))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityLabel("Dismiss message actions")
                    .accessibilityAddTraits(.isButton)
                ScrollView {
                    MessageActionMenu(
                        row: row, context: context, isReacting: isReacting,
                        onReaction: onReaction, onAction: onAction, onClose: onClose,
                        controlsWidth: controlsWidth
                    ) {
                        // Read-only preview uses the production bubble surface, not a second renderer.
                        TimelineBubbleView(
                            row: .message(row),
                            context: .init(
                                viewportSize: geometry.size,
                                currentUserID: currentUserID, isThreadTimeline: context.isThreadView,
                                isInteractionPreview: true),
                            mediaContext: mediaContext
                        )
                        .frame(width: previewWidth, alignment: row.isOutgoing ? .trailing : .leading)
                        .frame(maxHeight: min(220, geometry.size.height * 0.3), alignment: .top)
                        .clipShape(Rectangle().inset(by: -8))
                        .accessibilityHidden(true)
                    }
                    // Leave drawing room for the bubble tail without changing the text width.
                    .padding(.horizontal, 8)
                    .background {
                        GeometryReader { panel in
                            Color.clear
                                .onAppear { panelSize = panel.size }
                                .onChange(of: panel.size) { panelSize = $0 }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(width: width + 16, height: min(panelSize.height, max(1, geometry.size.height - 24)))
                .offset(x: x - 8, y: y)
                .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            #if os(macOS)
                .onExitCommand(perform: onClose)
            #endif
        }
        .transition(.opacity)
        .zIndex(100)
    }
}
