import SwiftUI

struct UnsupportedMessageBubble: View {
    let text: String
    let fontSize: CGFloat
    let symbolSize: CGSize
    let labelGap: CGFloat
    var body: some View {
        HStack(alignment: .top, spacing: labelGap) {
            Image(systemName: "questionmark.square.dashed")
                .resizable().scaledToFit().frame(width: symbolSize.width, height: symbolSize.height)
            Text(verbatim: text).font(.system(size: fontSize))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
