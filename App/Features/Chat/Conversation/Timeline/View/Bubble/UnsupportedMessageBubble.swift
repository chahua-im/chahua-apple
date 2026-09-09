import SwiftUI

struct UnsupportedMessageBubble: View {
    let row: TimelineMessageRow
    let context: TimelineRowContext
    var body: some View {
        MessageBubbleShell(row: row, context: context) {
            Label("This message type isn’t supported yet", systemImage: "questionmark.square.dashed")
        }
    }
}
