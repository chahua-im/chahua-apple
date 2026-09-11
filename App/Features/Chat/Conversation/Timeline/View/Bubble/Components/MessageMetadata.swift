import ChahuaAPI
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MessageMetadata {
    let time: String
    let state: ConversationMessageDisplayState?
    let size: CGSize
    private let attributedTime: NSAttributedString
    fileprivate let textSize: CGSize
    fileprivate let fontSize: CGFloat
    let symbol: BubbleNativeImage?
    fileprivate let textOpacity: CGFloat
    fileprivate let foreground: BubbleNativeColor

    init(time: String, state: ConversationMessageDisplayState?, isOutgoing: Bool, isOverlay: Bool = false, fontSize: CGFloat = 12) {
        self.time = time
        self.state = state
        textOpacity = isOverlay ? 1 : 0.7
        self.fontSize = fontSize
        foreground = isOutgoing || isOverlay ? .white : bubbleLabelColor
        let text = NSAttributedString(string: time, attributes: [
            .font: BubbleNativeFont.systemFont(ofSize: fontSize),
            .foregroundColor: foreground
        ])
        attributedTime = text
        textSize = text.size()
        size = CGSize(width: ceil(textSize.width) + (state == nil ? 0 : 4 + fontSize), height: ceil(max(textSize.height, fontSize)))
        if let state {
            let name: String
            switch state {
            case .queued, .sending: name = "checkmark.circle"
            case .delivered: name = "checkmark.circle.fill"
            case .failed: name = "exclamationmark.circle.fill"
            }
            let color = state == .failed ? BubbleNativeColor.systemRed : foreground.withAlphaComponent(isOverlay ? 1 : 0.7)
            #if os(macOS)
            let configuration = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
                .applying(.init(paletteColors: [color]))
            symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            #else
            let configuration = UIImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
                .applying(UIImage.SymbolConfiguration(paletteColors: [color]))
            symbol = UIImage(systemName: name, withConfiguration: configuration)
            #endif
        } else {
            symbol = nil
        }
    }

    init(row: TimelineMessageRow, isOverlay: Bool = false, fontSize: CGFloat = 12) {
        let time = row.entry.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: Locale.current.identifier + "@hours=h23")))
            + (row.entry.remoteMessage?.isEdited == true ? " " + String(localized: "(Edited)") : "")
        self.init(time: time, state: row.isOutgoing ? row.entry.displayState : nil,
                  isOutgoing: row.isOutgoing, isOverlay: isOverlay, fontSize: fontSize)
    }

    var accessibilityLabel: String {
        guard let state else { return time }
        let label: String
        switch state {
        case .queued: label = String(localized: "Queued")
        case .sending: label = String(localized: "Sending")
        case .delivered: label = String(localized: "Sent")
        case .failed: label = String(localized: "Failed to send")
        }
        return "\(time), \(label)"
    }

    func symbolFrame(in frame: CGRect) -> CGRect {
        guard symbol != nil, frame.width > 0, size.width > 0 else { return .zero }
        let scale = min(1, frame.width / size.width)
        return CGRect(
            x: frame.minX + (size.width - fontSize) * scale,
            y: frame.minY + (size.height - fontSize) / 2 * scale,
            width: fontSize * scale,
            height: fontSize * scale
        )
    }

    func draw(in frame: CGRect, drawsSymbol: Bool = true) {
        guard frame.width > 0, size.width > 0 else { return }
        #if os(macOS)
        let context = NSGraphicsContext.current?.cgContext
        #else
        let context = UIGraphicsGetCurrentContext()
        #endif
        guard let context else { return }
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.minY)
        let scale = min(1, frame.width / size.width)
        context.scaleBy(x: scale, y: scale)
        context.setAlpha(textOpacity)
        attributedTime.draw(at: CGPoint(x: 0, y: (size.height - textSize.height) / 2))
        context.restoreGState()
        if drawsSymbol {
            #if os(macOS)
            symbol?.draw(in: symbolFrame(in: frame), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            #else
            symbol?.draw(in: symbolFrame(in: frame))
            #endif
        }
    }
}

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
                                #if os(iOS)
                                .frame(minWidth: 44, minHeight: 44)
                                #endif
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
        #if os(macOS)
        Color(nsColor: metadata.foreground)
        #else
        Color(uiColor: metadata.foreground)
        #endif
    }

    private func symbolImage(_ symbol: BubbleNativeImage) -> Image {
        #if os(macOS)
        Image(nsImage: symbol).renderingMode(.original)
        #else
        Image(uiImage: symbol).renderingMode(.original)
        #endif
    }
}
