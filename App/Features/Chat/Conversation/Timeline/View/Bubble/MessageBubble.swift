import ChahuaAPI
import SwiftUI

/// Selects bubble content without owning any surrounding row affordances.
struct MessageBubble: View {
    let row: TimelineMessageRow
    let context: TimelineRowContext
    let actions: TimelineBubbleActions

    var body: some View {
        if row.entry.messageType == .system {
            SystemMessageBubble(row: row)
        } else if row.entry.remoteMessage?.isDeleted == true {
            DeletedMessageBubble(row: row)
        } else if row.entry.messageType == .text {
            TextMessageBubble(row: row, context: context, actions: actions)
        } else if row.entry.messageType == .sticker {
            StickerMessageBubble(row: row, context: context, actions: actions)
        } else {
            UnsupportedMessageBubble(row: row)
        }
    }
}
