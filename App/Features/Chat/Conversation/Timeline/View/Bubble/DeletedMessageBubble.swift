import SwiftUI

struct DeletedMessageBubble: View {
    let row: TimelineMessageRow
    var body: some View {
        MessageBubbleShell(row: row) {
            Text("Message deleted").italic()
        }
    }
}
