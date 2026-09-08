import SwiftUI

/// Both native hosts need exact, pre-computed row heights so their offset/anchor calculations
/// agree with SwiftUI bubble layout. The public `TimelineRowMeasurer` contract is identical on
/// each platform, but controller containment, typography environment, and pixel scale are not:
/// UIKit requires a child `UIHostingController` with safe-area suppression; AppKit requires an
/// `NSHostingController` and uses the window backing scale. Keep the branches explicit rather
/// than hiding those lifecycle differences behind a typealias abstraction.

#if os(iOS)
import UIKit


// UIKit host: attach the measuring controller to the visible parent so traits and Dynamic Type
// match the configured cells; placing it hidden and offscreen prevents it from affecting layout.
@MainActor
final class TimelineRowMeasurer {
    private struct CachedMeasurement {
        let row: TimelineRow
        let width: CGFloat
        let typographySignature: String
        let scale: CGFloat
        let height: CGFloat
    }

    private unowned let parent: UIViewController
    private var host: UIHostingController<TimelineBubbleView>?
    private var cache: [TimelineRowID: CachedMeasurement] = [:]

    init(parent: UIViewController) {
        self.parent = parent
    }

    func height(for row: TimelineRow, width: CGFloat) -> CGFloat {
        let typographySignature = parent.traitCollection.preferredContentSizeCategory.rawValue
        let scale = parent.view.traitCollection.displayScale
        if let cached = cache[row.id], cached.row == row, cached.width == width, cached.typographySignature == typographySignature, cached.scale == scale { return cached.height }
        let host = hostingController(for: row)
        host.rootView = TimelineBubbleView(row: row, context: .init())
        let measured = host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        let height = ceil(measured * scale) / scale
        cache[row.id] = .init(row: row, width: width, typographySignature: typographySignature, scale: scale, height: height)
        return height
    }

    func invalidateAll() { cache.removeAll(keepingCapacity: true) }
    func remove(_ ids: Set<TimelineRowID>) {
        for id in ids { cache.removeValue(forKey: id) }
    }

    private func hostingController(for row: TimelineRow) -> UIHostingController<TimelineBubbleView> {
        if let host { return host }
        let host = UIHostingController(rootView: TimelineBubbleView(row: row, context: .init()))
        host.safeAreaRegions = []
        host.view.isHidden = true
        host.view.frame = CGRect(x: 0, y: -10_000, width: 1, height: 1)
        parent.addChild(host)
        parent.view.addSubview(host.view)
        host.didMove(toParent: parent)
        self.host = host
        return host
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
        let textLayout: MacBubbleTextLayout?
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
        let textLayout: MacBubbleTextLayout?
        if let previous, previous.row == row, previous.context == measurementContext,
           previous.typographySignature == typographySignature, let layout = previous.textLayout {
            measured = MacBubbleMetrics.textOnlyHeight(layout: layout, rowWidth: width)
            textLayout = layout
        } else if isTextOnly(row), case .message(let message) = row {
            let text = message.entry.text ?? ""
            let layout = MacBubbleTextLayout(
                attributedText: MacBubbleTextContent.attributedText(
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text,
                    mentions: message.entry.remoteMessage?.mentions ?? [],
                    currentUserID: context.currentUserID, isOutgoing: message.isOutgoing,
                    font: .systemFont(ofSize: typographySignature)
                ),
                metadata: MacBubbleMetadata(row: message)
            )
            measured = MacBubbleMetrics.textOnlyHeight(layout: layout, rowWidth: width)
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
        return (remote?.attachments.isEmpty ?? true) && remote?.replyToMessage == nil && remote?.threadInfo == nil
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
