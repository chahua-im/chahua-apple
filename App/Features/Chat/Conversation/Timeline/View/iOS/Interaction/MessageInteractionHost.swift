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
            return row(for: target.key)
        }

        private func row(for key: ConversationMessageStableKey) -> TimelineMessageRow? {
            for row in model.rows {
                if case .message(let message) = row, message.entry.stableKey == key {
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
            if isSelectingMessages || !context.canWriteContent { result.toggleReaction = nil }
            if isSelectingMessages { result.openReactionDetails = nil }
            if isSelectingMessages || target != nil || !context.canStageDraft {
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
                        presentation: presentation,
                        reduceMotion: reduceMotion)
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

        private func menuContext(for row: TimelineMessageRow) -> MessageInteractionContext {
            var result = actions.pinContext(for: row, base: context)
            if let message = row.entry.remoteMessage {
                result.isFavoriteSticker = actions.isStickerFavorite?(message) ?? false
            }
            return result
        }

        private var presentation: MessageInteractionPresentation? {
            if let target, let row = selectedRow {
                return MessageInteractionPresentation(
                    row: row, context: menuContext(for: row),
                    currentUserID: model.currentUserID,
                    source: target.source,
                    mediaContext: mediaContext, actions: actions,
                    interfaceStyle: colorScheme == .dark ? .dark : .light,
                    onEditPending: { pending in
                        guard actions.canEditPendingMessage(pending) else { return }
                        self.target = nil
                        actions.editPendingMessage?(pending)
                    },
                    onRemovePending: { pending in
                        guard actions.canRemovePendingMessage(pending) else { return }
                        self.target = nil
                        actions.removePendingMessage?(pending)
                    },
                    isReacting: actions.isReacting(to: row.entry),
                    onReaction: { emoji in
                        guard !isSelectingMessages, let liveRow = selectedRow,
                            MessageActionPolicy(row: liveRow, context: context).canReact
                        else { return }
                        actions.toggleReaction?(liveRow, emoji)
                    },
                    onAction: { action in
                        guard !isSelectingMessages, let liveRow = self.row(for: target.key),
                            MessageActionPolicy(
                                row: liveRow,
                                context: menuContext(for: liveRow)
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
                        } else if action == .save, let message = liveRow.entry.remoteMessage {
                            self.target = nil
                            actions.toggleSavedMessage?(message)
                        } else if action == .favorite, let message = liveRow.entry.remoteMessage,
                            let toggleFavorite = actions.toggleStickerFavorite,
                            !(message.sticker.map { actions.pendingStickerIDs.contains($0.id) }
                                ?? false)
                        {
                            self.target = nil
                            toggleFavorite(message)
                        } else if action == .toSticker, let message = liveRow.entry.remoteMessage,
                            let addToStickerPack = actions.addMessageToStickerPack
                        {
                            self.target = nil
                            addToStickerPack(message)
                        } else if action == .copyLink, let message = liveRow.entry.remoteMessage,
                            let link = MessagePermalink(
                                chatID: message.chatId, messageID: message.id)
                        {
                            UIPasteboard.general.string = link.url.absoluteString
                            self.target = nil
                            actions.didCopyMessage?()
                        } else if action == .copy, let text = liveRow.entry.clipboardText {
                            UIPasteboard.general.string = text
                            self.target = nil
                            actions.didCopyMessage?()
                        }
                    },
                    onClose: { self.target = nil }
                )
            }
            return nil
        }
    }

#endif
