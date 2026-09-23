import ChahuaAPI
import CoreText
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
    private let timeLine: CTLine
    private let textBounds: CGRect
    let textSize: CGSize
    let fontSize: CGFloat
    let symbol: BubbleNativeImage?
    let textOpacity: CGFloat
    let foreground: BubbleNativeColor

    init(
        time: String, state: ConversationMessageDisplayState?, isOutgoing: Bool,
        isOverlay: Bool = false, fontSize: CGFloat = 12
    ) {
        self.time = time
        self.state = state
        textOpacity = isOverlay ? 1 : 0.7
        self.fontSize = fontSize
        foreground = isOutgoing || isOverlay ? .white : bubbleLabelColor
        let text = NSAttributedString(
            string: time,
            attributes: [
                .font: BubbleNativeFont.systemFont(ofSize: fontSize),
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
        let line = CTLineCreateWithAttributedString(text)
        timeLine = line
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        // Measure and draw the same native line. Attributed-string size()/draw(at:)
        // do not provide a shared baseline or preserve glyph overhangs; a separate
        // metadata row has no following line to absorb pixels outside that estimate.
        let typographicBounds = CGRect(
            x: 0, y: -descent, width: advance,
            height: ascent + descent + max(0, leading))
        textBounds =
            typographicBounds.union(CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)).integral
        textSize = textBounds.size
        size = CGSize(
            width: ceil(textSize.width) + (state == nil ? 0 : 4 + fontSize),
            height: ceil(max(textSize.height, fontSize)))
        if let state {
            let name: String
            switch state {
            case .queued, .sending: name = "checkmark.circle"
            case .delivered: name = "checkmark.circle.fill"
            case .failed: name = "exclamationmark.circle.fill"
            }
            let color =
                state == .failed
                ? BubbleNativeColor.systemRed : foreground.withAlphaComponent(isOverlay ? 1 : 0.7)
            #if os(macOS)
                let configuration = NSImage.SymbolConfiguration(
                    pointSize: fontSize, weight: .regular
                )
                .applying(.init(paletteColors: [color]))
                symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
            #else
                let configuration = UIImage.SymbolConfiguration(
                    pointSize: fontSize, weight: .regular
                )
                .applying(UIImage.SymbolConfiguration(paletteColors: [color]))
                symbol = UIImage(systemName: name, withConfiguration: configuration)
            #endif
        } else {
            symbol = nil
        }
    }

    init(row: TimelineMessageRow, isOverlay: Bool = false, fontSize: CGFloat = 12) {
        let time =
            row.entry.createdAt.formatted(
                .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(
                    Locale(identifier: Locale.current.identifier + "@hours=h23")))
            + (row.entry.remoteMessage?.isEdited == true ? " " + String(localized: "(Edited)") : "")
        self.init(
            time: time, state: row.isOutgoing ? row.entry.displayState : nil,
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
        // Resolve semantic colors in the displaying view's appearance, not when
        // the cached line is created. Core Text uses an upward-positive baseline.
        context.setFillColor(foreground.cgColor)
        context.translateBy(
            x: -textBounds.minX, y: (size.height - textSize.height) / 2 + textBounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(timeLine, context)
        context.restoreGState()
        if drawsSymbol {
            #if os(macOS)
                symbol?.draw(
                    in: symbolFrame(in: frame), from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
            #else
                symbol?.draw(in: symbolFrame(in: frame))
            #endif
        }
    }
}
