import SwiftUI

struct TextMessageBubble: View {
    let row: TimelineMessageRow
    var body: some View {
        MessageBubbleShell(row: row) {
            Text(row.entry.text ?? "").textSelection(.enabled)
        }
    }
}
