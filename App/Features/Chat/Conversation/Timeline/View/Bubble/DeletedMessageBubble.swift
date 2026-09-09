import SwiftUI

struct DeletedMessageBubble: View {
    let row: TimelineMessageRow
    let context: TimelineRowContext
    var body: some View {
        MessageBubbleShell(row: row, context: context) {
            Text("Message deleted").italic()
        }
    }
}
