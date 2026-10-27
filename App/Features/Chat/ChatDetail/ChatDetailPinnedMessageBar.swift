import ChahuaAPI
import SwiftUI

/// Pin availability determines header geometry; only this child observes the date
/// used to select a pin. Scrolling must not invalidate the screen or its composer.
struct ChatDetailPinnedMessageBar: View {
    let chatID: String
    @ObservedObject var controller: ChatPinController
    @ObservedObject var viewport: TimelineViewportPresentation
    let canManage: Bool
    @Binding var showsPinnedMessages: Bool
    let onJump: (MessageResponse) -> Void
    let onOpenThread: ((MessageResponse) -> Void)?
    let onRequestPinChange: (MessageResponse) -> Void

    private var pins: [PinResponse] { controller.pinsByChatID[chatID] ?? [] }

    var body: some View {
        if let pin = ChatPinSelection.activePin(
            in: pins, bottomVisibleMessageDate: viewport.value.bottomVisibleMessageDate)
        {
            ChatPinnedMessageBar(
                pin: pin, count: pins.count,
                onJump: { onJump(pin.message) },
                onShowAll: { showsPinnedMessages = true },
                onOpenThread: pin.message.threadInfo != nil && onOpenThread != nil
                    ? { onOpenThread?(pin.message) } : nil,
                onUnpin: canManage && !controller.pendingMessageIDs.contains(pin.message.id)
                    ? { onRequestPinChange(pin.message) } : nil
            )
            .popover(
                isPresented: $showsPinnedMessages, attachmentAnchor: .rect(.bounds), arrowEdge: .top
            ) {
                ChatPinnedMessagesSheet(
                    chatID: chatID, controller: controller, canManage: canManage,
                    onSelect: onJump, onOpenThread: onOpenThread
                )
                .frame(width: 420, height: 420)
            }
        } else if controller.failedChatIDs.contains(chatID) {
            Button {
                Task { await controller.load(chatID: chatID, force: true) }
            } label: {
                Label("Couldn’t load pinned messages. Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .modifier(ChatGlassSurface(cornerRadius: 24))
        }
    }
}
