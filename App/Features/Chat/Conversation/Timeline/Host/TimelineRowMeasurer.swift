import SwiftUI

/// Both native hosts need exact, pre-computed row heights so their offset/anchor calculations
/// agree with SwiftUI bubble layout. The public `TimelineRowMeasurer` contract is identical on
/// each platform, but controller containment, typography environment, and pixel scale are not:
/// UIKit requires a child `UIHostingController` with safe-area suppression; AppKit requires an
/// `NSHostingController` and uses the window backing scale. Keep the branches explicit rather
/// than hiding those lifecycle differences behind a typealias abstraction.

#if canImport(UIKit)
import UIKit


// UIKit host: attach the measuring controller to the visible parent so traits and Dynamic Type
// match the configured cells; placing it hidden and offscreen prevents it from affecting layout.
@MainActor
final class TimelineRowMeasurer {
    private struct CachedMeasurement {
        let row: TimelineRow
        let width: CGFloat
        let typographySignature: String
        let height: CGFloat
    }

    private let parent: UIViewController
    private var host: UIHostingController<TimelineBubbleView>?
    private var cache: [TimelineRowID: CachedMeasurement] = [:]

    init(parent: UIViewController) {
        self.parent = parent
    }

    func height(for row: TimelineRow, width: CGFloat) -> CGFloat {
        let typographySignature = parent.traitCollection.preferredContentSizeCategory.rawValue
        if let cached = cache[row.id], cached.row == row, cached.width == width, cached.typographySignature == typographySignature { return cached.height }
        let host = hostingController(for: row)
        host.rootView = TimelineBubbleView(row: row, context: .init())
        let measured = host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        let scale = parent.view.traitCollection.displayScale
        let height = ceil(measured * scale) / scale
        cache[row.id] = .init(row: row, width: width, typographySignature: typographySignature, height: height)
        return height
    }

    func invalidateAll() { cache.removeAll(keepingCapacity: true) }
    func retain(only ids: Set<TimelineRowID>) { cache = cache.filter { ids.contains($0.key) } }

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
#elseif canImport(AppKit)
import AppKit

// AppKit host: NSHostingController follows AppKit containment and backing-scale behavior; it is
// deliberately separate from the UIKit setup above rather than a shared typealias shim.

@MainActor
final class TimelineRowMeasurer {
    private struct CachedMeasurement {
        let row: TimelineRow
        let width: CGFloat
        let typographySignature: CGFloat
        let height: CGFloat
    }

    private let parent: NSViewController
    private var host: NSHostingController<TimelineBubbleView>?
    private var cache: [TimelineRowID: CachedMeasurement] = [:]

    init(parent: NSViewController) {
        self.parent = parent
    }

    func height(for row: TimelineRow, width: CGFloat) -> CGFloat {
        let typographySignature = NSFont.preferredFont(forTextStyle: .body).pointSize
        if let cached = cache[row.id], cached.row == row, cached.width == width, cached.typographySignature == typographySignature { return cached.height }
        let host = hostingController(for: row)
        host.rootView = TimelineBubbleView(row: row, context: .init())
        let measured = host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        let scale = parent.view.window?.backingScaleFactor ?? 2
        let height = ceil(measured * scale) / scale
        cache[row.id] = .init(row: row, width: width, typographySignature: typographySignature, height: height)
        return height
    }

    func invalidateAll() { cache.removeAll(keepingCapacity: true) }
    func retain(only ids: Set<TimelineRowID>) { cache = cache.filter { ids.contains($0.key) } }

    private func hostingController(for row: TimelineRow) -> NSHostingController<TimelineBubbleView> {
        if let host { return host }
        let host = NSHostingController(rootView: TimelineBubbleView(row: row, context: .init()))
        host.view.isHidden = true
        parent.addChild(host)
        parent.view.addSubview(host.view)
        self.host = host
        return host
    }
}
#endif
