import SwiftUI

struct UnsupportedMessageBubble: View {
    let row: TimelineMessageRow
    var body: some View {
        MessageBubbleShell(row: row) {
            Label("This message type isn’t supported yet", systemImage: "questionmark.square.dashed")
        }
    }
}
