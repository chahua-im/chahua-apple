import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One replaceable transaction per display tick. The display link never owns its client.
@MainActor
final class TimelineDisplayScheduler {
    @MainActor
    private final class Target: NSObject {
        weak var owner: TimelineDisplayScheduler?
        @objc func tick(_ link: CADisplayLink) { owner?.flush() }
    }

    private let target = Target()
    private var link: CADisplayLink?
    private var pending: (@MainActor () -> Void)?

    #if os(macOS)
    init(view: NSView) {
        target.owner = self
        link = view.displayLink(target: target, selector: #selector(Target.tick(_:)))
        link?.isPaused = true
        link?.add(to: .main, forMode: .common)
    }
    #else
    init(view: UIView) {
        target.owner = self
        link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link?.isPaused = true
        link?.add(to: .main, forMode: .common)
    }
    #endif

    func request(_ action: @escaping @MainActor () -> Void) {
        pending = action
        link?.isPaused = false
    }

    func flush() {
        let action = pending
        pending = nil
        link?.isPaused = true
        action?()
    }

    func cancel() {
        pending = nil
        link?.isPaused = true
    }

    deinit { link?.invalidate() }
}
