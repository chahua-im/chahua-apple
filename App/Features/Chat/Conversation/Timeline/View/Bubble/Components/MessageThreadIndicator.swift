import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum MessageNativeSymbol {
    static func size(_ name: String, fontSize: CGFloat, semibold: Bool) -> CGSize {
        #if os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: fontSize, weight: semibold ? .semibold : .regular))?.size ?? .zero
        #else
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize, weight: semibold ? .semibold : .regular))?.size ?? .zero
        #endif
    }
}

struct MessageThreadIndicator: View {
    let label: String
    let fontSize: CGFloat
    let symbolSize: CGSize
    let labelGap: CGFloat
    var action: (() -> Void)?

    var body: some View {
        if let action {
            MessageRowActionButton(action: action) { content }
        } else { content }
    }

    private var content: some View {
        HStack(spacing: labelGap) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .resizable().scaledToFit().frame(width: symbolSize.width, height: symbolSize.height)
            Text(verbatim: label).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .clipped()
        .opacity(0.8)
    }
}
