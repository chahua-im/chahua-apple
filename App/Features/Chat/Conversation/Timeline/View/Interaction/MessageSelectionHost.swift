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
        result.extendMessageSelection = extend
        result.endMessageSelection = cancel
        result.removeSelectedMessage = { id in
            selected.removeValue(forKey: id)
            synchronizeRange()
        }
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
            .onChange(of: actions.isSelectionBusy) { _, _ in synchronizeRange() }
            .onChange(of: ObjectIdentifier(model)) { _, _ in cancel() }
            .onDisappear(perform: cancel)
            .alert("Select up to 100 messages", isPresented: $limitReached) {
                Button("OK", role: .cancel) {}
            }
    }

    private func toggle(_ message: MessageResponse) {
        guard !actions.isSelectionBusy, model.canSelectMessage(message) else { return }
        if selected.removeValue(forKey: message.id) != nil {
            synchronizeRange()
            return
        }
        guard selected.count < TimelineSelectionRange.limit else {
            limitReached = true
            return
        }
        selected[message.id] = message
        active = true
        synchronizeRange()
    }

    private func extend(_ direction: TimelineSelectionRange.Direction) {
        guard active, !actions.isSelectionBusy,
            let visibleIDs = model.selectionViewportSource?.visibleMessageIDsForSelection(),
            let messages = model.selectionRangeMessages(toward: direction, visibleIDs: visibleIDs)
        else { return }
        var next = selected
        for message in messages { next[message.id] = message }
        selected = next
        synchronizeRange()
    }

    private func synchronizeRange() {
        model.updateSelectionRange(
            active: active, ids: selected.keys, busy: actions.isSelectionBusy)
    }

    private func reconcile() {
        selected = selected.filter { !model.knownDeletedMessageIDs.contains($0.key) }
        for case .message(let row) in model.rows {
            guard let message = row.entry.remoteMessage, selected[message.id] != nil else {
                continue
            }
            if !model.canSelectMessage(message) {
                selected.removeValue(forKey: message.id)
            } else {
                selected[message.id] = message
            }
        }
        synchronizeRange()
    }

    private func cancel() {
        active = false
        selected.removeAll()
        synchronizeRange()
    }
}
