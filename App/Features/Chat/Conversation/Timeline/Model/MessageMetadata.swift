import ChahuaAPI
import CoreText
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

struct MessageMetadata {
    static let defaultFontSize: CGFloat = 11

    let time: String
    let state: ConversationMessageDisplayState?
    let isRead: Bool
    let size: CGSize
    private let timeLine: CTLine
    private let textBounds: CGRect
    let textSize: CGSize
    let fontSize: CGFloat
    let statusFontSize: CGFloat
    let checkSeparation: CGFloat
    let textOpacity: CGFloat
    let foreground: BubbleNativeColor
    private let statusSize: CGSize
    private let capHeight: CGFloat

    init(
        time: String, state: ConversationMessageDisplayState?, isOutgoing: Bool,
        isRead: Bool = false, isOverlay: Bool = false, fontSize: CGFloat = Self.defaultFontSize,
        checkSeparation: CGFloat = MessageDeliveryStatusView.defaultCheckSeparation
    ) {
        self.time = time
        self.state = state
        self.isRead = isRead && state == .delivered
        statusFontSize = fontSize * 12 / 11
        self.checkSeparation = checkSeparation
        statusSize = MessageDeliveryStatusView.layoutSize(
            for: statusFontSize, checkSeparation: checkSeparation)
        textOpacity = isOverlay ? 0.85 : isOutgoing ? 0.6 : 0.7
        self.fontSize = fontSize
        foreground = isOutgoing || isOverlay ? .white : bubbleLabelColor
        let font = BubbleNativeFont.systemFont(ofSize: fontSize)
        capHeight = font.capHeight
        let text = NSAttributedString(
            string: time,
            attributes: [
                .font: font,
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
            width: ceil(textSize.width) + (state == nil ? 0 : fontSize * 2 / 11 + statusSize.width),
            height: ceil(max(textSize.height, statusSize.height)))
    }

    init(
        row: TimelineMessageRow, isOverlay: Bool = false,
        fontSize: CGFloat = Self.defaultFontSize
    ) {
        let time =
            row.entry.createdAt.formatted(
                .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(
                    Locale(identifier: Locale.current.identifier + "@hours=h23")))
            + (row.entry.remoteMessage?.isEdited == true
                ? " " + AppLanguage.localized("(Edited)") : "")
        self.init(
            time: time, state: row.isOutgoing ? row.entry.displayState : nil,
            isOutgoing: row.isOutgoing, isRead: row.isRead, isOverlay: isOverlay, fontSize: fontSize
        )
    }

    /// Footer-only outsets leave the body's wrapping width and padding unchanged.
    var textTrailingOutset: CGFloat { fontSize * 2 / 11 }
    var textBaselineDrop: CGFloat { fontSize * 2 / 11 }
    private var textBaseline: CGFloat {
        (size.height - textSize.height) / 2 + textBounds.maxY
    }

    var status: MessageDeliveryStatusView.Status? {
        switch state {
        case .queued: .queued
        case .sending: .sending
        case .delivered: isRead ? .read : .sent
        case .failed: .failed
        case nil: nil
        }
    }

    var digitHeight: CGFloat { capHeight }

    @MainActor
    var statusContent: MessageDeliveryStatusContent? {
        guard let status else { return nil }
        return MessageDeliveryStatusContent(
            status: status, size: statusFontSize, foreground: Color(foreground),
            checkSeparation: checkSeparation, checkHeight: capHeight)
    }

    var accessibilityLabel: String {
        guard let state else { return time }
        let label: String
        switch state {
        case .queued: label = AppLanguage.localized("Queued")
        case .sending: label = AppLanguage.localized("Sending")
        case .delivered: label = AppLanguage.localized(isRead ? "Read" : "Sent")
        case .failed: label = AppLanguage.localized("Failed to send")
        }
        return "\(time), \(label)"
    }

    func statusFrame(in frame: CGRect) -> CGRect {
        guard state != nil, frame.width > 0, size.width > 0 else { return .zero }
        let scale = min(1, frame.width / size.width)
        // The check's visible ink and the timestamp digits share the same center and height.
        let statusY = textBaseline - capHeight / 2 - statusSize.height / 2
        return CGRect(
            x: frame.minX + (size.width - statusSize.width) * scale,
            y: frame.minY + statusY * scale,
            width: statusSize.width * scale,
            height: statusSize.height * scale
        )
    }

    func draw(in frame: CGRect) {
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
    }
}
