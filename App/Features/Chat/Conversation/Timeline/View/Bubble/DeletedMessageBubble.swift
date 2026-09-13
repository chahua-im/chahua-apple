import SwiftUI

struct DeletedMessageBubble: View {
    let text: String
    let fontSize: CGFloat
    var body: some View {
        Text(verbatim: text)
            .font(.system(size: fontSize))
            .italic()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
