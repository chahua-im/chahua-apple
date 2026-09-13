#if os(iOS)
import ChahuaAPI
import SwiftUI

struct SystemMessageBubble: View {
    let row: TimelineMessageRow
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(textColor)
            .lineSpacing(3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var content: Text {
        let message = text
        if let senderName = row.entry.remoteMessage?.sender.name, !senderName.isEmpty {
            return Text("\(Text(verbatim: senderName).fontWeight(.semibold)) \(Text(verbatim: message))")
        }
        return Text(verbatim: message)
    }

    private var textColor: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 152.0 / 255, green: 154.0 / 255, blue: 162.0 / 255, opacity: 1)
            : Color(.sRGB, red: 99.0 / 255, green: 100.0 / 255, blue: 105.0 / 255, opacity: 1)
    }
}


#endif
