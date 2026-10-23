import ChahuaAPI
import SwiftUI

/// Selection belongs to the conversation, not recycled native rows or a platform menu.
struct MessageSelectionHost<Content: View>: View {
    @ObservedObject var model: ConversationTimelineModel
    var actions: TimelineBubbleActions
    @ViewBuilder var content: (TimelineBubbleActions) -> Content
    @State private var active = false
    @State private var selected: [MessageID: MessageResponse] = [:]
    @State private var limitReached = false

    private var routedActions: TimelineBubbleActions {
        var result = actions
        result.isSelectingMessages = active
        result.selectedMessageIDs = Set(selected.keys)
        result.selectionMessages = selected.values.sorted { $0.id < $1.id }
        result.toggleMessageSelection = toggle
        result.endMessageSelection = cancel
        result.removeSelectedMessage = { id in selected.removeValue(forKey: id) }
        if active {
            result.replyToMessage = nil
            result.toggleReaction = nil
            result.openReactionDetails = nil
            result.openContextMenu = nil
        }
        return result
    }

    var body: some View {
        content(routedActions)
            .onChange(of: model.rows) { _, _ in reconcile() }
            .onChange(of: model.knownDeletedMessageIDs) { _, _ in reconcile() }
            .onChange(of: ObjectIdentifier(model)) { _, _ in cancel() }
            .onDisappear(perform: cancel)
            .alert("Select up to 100 messages", isPresented: $limitReached) {
                Button("OK", role: .cancel) {}
            }
    }

    private func toggle(_ message: MessageResponse) {
        guard !actions.isSelectionBusy, !message.isDeleted, message.messageType != .system,
            message.chatId == model.chatID, !model.knownDeletedMessageIDs.contains(message.id)
        else { return }
        if selected.removeValue(forKey: message.id) != nil { return }
        guard selected.count < 100 else {
            limitReached = true
            return
        }
        selected[message.id] = message
        active = true
    }

    private func reconcile() {
        selected = selected.filter { !model.knownDeletedMessageIDs.contains($0.key) }
        for case .message(let row) in model.rows {
            guard let message = row.entry.remoteMessage, selected[message.id] != nil else {
                continue
            }
            if message.isDeleted || message.messageType == .system {
                selected.removeValue(forKey: message.id)
            } else {
                selected[message.id] = message
            }
        }
    }

    private func cancel() {
        active = false
        selected.removeAll()
    }
}
