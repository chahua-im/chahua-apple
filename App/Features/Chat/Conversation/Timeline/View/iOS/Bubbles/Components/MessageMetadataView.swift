#if os(iOS)
import SwiftUI

/// Standalone metadata uses the same font, native symbol, and measured frames as
/// inline text metadata, without allocating text storage or a layout manager.
struct MessageMetadataView: View {
    let metadata: MessageMetadata
    var failureAction: (() -> Void)? = nil

    var body: some View {
        Text(verbatim: metadata.time)
            .font(.system(size: metadata.fontSize))
            .foregroundStyle(timeColor)
            .opacity(metadata.textOpacity)
            .fixedSize()
            .frame(width: metadata.textSize.width, height: metadata.textSize.height)
            .frame(width: metadata.size.width, height: metadata.size.height, alignment: .leading)
            .accessibilityLabel(metadata.accessibilityLabel)
            .overlay(alignment: .topLeading) {
                if let symbol = metadata.symbol {
                    let frame = metadata.symbolFrame(in: CGRect(origin: .zero, size: metadata.size))
                    if metadata.state == .failed, let failureAction {
                        MessageRowActionButton(action: failureAction) {
                            symbolImage(symbol)
                                .resizable()
                                .frame(width: frame.width, height: frame.height)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Failed to send. Retry options"))
                        .position(x: frame.midX, y: frame.midY)
                    } else {
                        symbolImage(symbol)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .accessibilityHidden(true)
                    }
                }
            }
    }

    private var timeColor: Color {
        Color(uiColor: metadata.foreground)
    }

    private func symbolImage(_ symbol: BubbleNativeImage) -> Image {
        Image(uiImage: symbol).renderingMode(.original)
    }
}


#endif
