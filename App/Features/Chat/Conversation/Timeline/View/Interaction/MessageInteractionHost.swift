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
            let width = min(276, max(1, geometry.size.width - 24))
            let origin = geometry.frame(in: .global).origin
            let localSource = source.offsetBy(dx: -origin.x, dy: -origin.y)
            let proposedX = row.isOutgoing ? localSource.maxX - width : localSource.minX
            let x = min(max(12, proposedX), max(12, geometry.size.width - width - 12))
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
                        onReaction: onReaction, onAction: onAction, onClose: onClose
                    ) {
                        // Read-only preview uses the production bubble surface, not a second renderer.
                        TimelineBubbleView(
                            row: .message(row),
                            context: .init(
                                viewportSize: CGSize(width: width, height: geometry.size.height),
                                currentUserID: currentUserID, isThreadTimeline: context.isThreadView,
                                isInteractionPreview: true),
                            mediaContext: mediaContext
                        )
                        .frame(width: width, alignment: row.isOutgoing ? .trailing : .leading)
                        .frame(maxHeight: min(220, geometry.size.height * 0.3), alignment: .top)
                        .clipped()
                        .accessibilityHidden(true)
                    }
                    .background {
                        GeometryReader { panel in
                            Color.clear
                                .onAppear { panelSize = panel.size }
                                .onChange(of: panel.size) { panelSize = $0 }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(width: width, height: min(panelSize.height, max(1, geometry.size.height - 24)))
                .offset(x: x, y: y)
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
