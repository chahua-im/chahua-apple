import SwiftUI

/// Both native hosts measure the same bubble with the same layout context.
/// Hosting remains native so measurement inherits the visible cells' typography
/// and fitting behavior. Highlighting never participates in the height cache.

#if os(iOS)
import UIKit


// Match the visible cells' safe-area-free hosting and inherited typography.
@MainActor
final class TimelineRowMeasurer {
    private struct CachedMeasurement {
        let row: TimelineRow
        let width: CGFloat
        let context: TimelineRowContext
        let typographySignature: String
        let scale: CGFloat
        let height: CGFloat
    }

    private unowned let parent: UIViewController
    private var host: TimelineBubbleHostingController?
    private var cache: [TimelineRowID: CachedMeasurement] = [:]

    init(parent: UIViewController) {
        self.parent = parent
    }

    func height(for row: TimelineRow, width: CGFloat, context: TimelineRowContext) -> CGFloat {
        let typographySignature = parent.traitCollection.preferredContentSizeCategory.rawValue
        let scale = parent.view.traitCollection.displayScale
        var measurementContext = context
        measurementContext.isHighlighted = false
        measurementContext.isMeasuring = true
        if let cached = cache[row.id], cached.row == row, cached.width == width, cached.context == measurementContext, cached.typographySignature == typographySignature, cached.scale == scale { return cached.height }
        let root = TimelineBubbleView(row: row, context: measurementContext)
        let measuringHost: TimelineBubbleHostingController
        if let host {
            measuringHost = host
            host.rootView = root
        } else {
            measuringHost = TimelineBubbleHostingController(rootView: root)
            measuringHost.view.isHidden = true
            parent.addChild(measuringHost)
            parent.view.addSubview(measuringHost.view)
            measuringHost.didMove(toParent: parent)
            host = measuringHost
        }
        measuringHost.view.frame = CGRect(x: 0, y: -10_000, width: width, height: 0)
        let measured = measuringHost.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        let height = ceil(measured * scale) / scale
        cache[row.id] = .init(row: row, width: width, context: measurementContext, typographySignature: typographySignature, scale: scale, height: height)
        return height
    }

    func invalidateAll() { cache.removeAll(keepingCapacity: true) }
    func remove(_ ids: Set<TimelineRowID>) {
        for id in ids { cache.removeValue(forKey: id) }
    }

}
#elseif os(macOS)
import AppKit
import ChahuaAPI

// AppKit host: NSHostingController follows AppKit containment and backing-scale behavior; it is
// deliberately separate from the UIKit setup above rather than a shared typealias shim.

@MainActor
final class TimelineRowMeasurer {
    private struct CachedMeasurement {
        let row: TimelineRow
        let width: CGFloat
        let context: TimelineRowContext
        let typographySignature: CGFloat
        let scale: CGFloat
        let height: CGFloat
        let textLayout: BubbleTextLayout?
    }

    private unowned let parent: NSViewController
    private var host: NSHostingController<TimelineBubbleView>?
    private var cache: [TimelineRowID: CachedMeasurement] = [:]

    init(parent: NSViewController) {
        self.parent = parent
    }

    func height(for row: TimelineRow, width: CGFloat, context: TimelineRowContext) -> CGFloat {
        let typographySignature = NSFont.preferredFont(forTextStyle: .body).pointSize
        let scale = parent.view.window?.backingScaleFactor ?? 2
        let measurementContext = TimelineRowContext(
            isHighlighted: false,
            viewportSize: context.viewportSize,
            currentUserID: context.currentUserID,
            isThreadTimeline: context.isThreadTimeline,
            isMeasuring: true
        )
        if let cached = cache[row.id], cached.row == row, cached.width == width, cached.context == measurementContext, cached.typographySignature == typographySignature, cached.scale == scale { return cached.height }
        let previous = cache[row.id]
        let measured: CGFloat
        let textLayout: BubbleTextLayout?
        if let previous, previous.row == row, previous.context == measurementContext,
           previous.typographySignature == typographySignature, let layout = previous.textLayout {
            measured = BubbleMetrics.textOnlyHeight(layout: layout, rowWidth: width)
            textLayout = layout
        } else if isTextOnly(row), case .message(let message) = row {
            let text = message.entry.text ?? ""
            let layout = BubbleTextLayout(
                attributedText: BubbleTextContent.attributedText(
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text,
                    mentions: message.entry.remoteMessage?.mentions ?? [],
                    currentUserID: context.currentUserID, isOutgoing: message.isOutgoing,
                    font: .systemFont(ofSize: typographySignature)
                ),
                metadata: BubbleMetadata(row: message)
            )
            measured = BubbleMetrics.textOnlyHeight(layout: layout, rowWidth: width)
            textLayout = layout
        } else {
            let host = hostingController(for: row)
            host.rootView = TimelineBubbleView(row: row, context: measurementContext)
            measured = host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
            textLayout = nil
        }
        let height = ceil(measured * scale) / scale
        cache[row.id] = .init(row: row, width: width, context: measurementContext, typographySignature: typographySignature, scale: scale, height: height, textLayout: textLayout)
        return height
    }

    func cachedHeight(for row: TimelineRow) -> CGFloat? {
        guard let cached = cache[row.id], cached.row == row else { return nil }
        return cached.height
    }

    func remove(_ ids: Set<TimelineRowID>) {
        for id in ids {
            cache.removeValue(forKey: id)
        }
    }

    private func isTextOnly(_ row: TimelineRow) -> Bool {
        guard case .message(let message) = row, message.entry.messageType == .text,
              !message.showsSenderName, message.entry.remoteMessage?.isDeleted != true else { return false }
        let remote = message.entry.remoteMessage
        return (remote?.attachments.isEmpty ?? true) && (remote?.reactions.isEmpty ?? true)
            && message.entry.replyToMessage == nil && remote?.threadInfo == nil
    }


    private func hostingController(for row: TimelineRow) -> NSHostingController<TimelineBubbleView> {
        if let host { return host }
        let host = NSHostingController(rootView: TimelineBubbleView(row: row, context: .init()))
        host.view.isHidden = true
        parent.addChild(host)
        self.host = host
        return host
    }
}
#endif
