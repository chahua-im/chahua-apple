import Foundation
import os

/// Local Instruments diagnostics, available in optimized builds. No timers, frame-rate
/// overrides, or user content; disabled launches do not initialize the signposter.
nonisolated enum ScrollPerformanceTrace {
    static let isRequested =
        ProcessInfo.processInfo.arguments.contains("-scroll-profiling")
        || ProcessInfo.processInfo.environment["CHAHUA_SCROLL_PROFILING"] == "1"
    private static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "app.chahua.chat", category: .pointsOfInterest))

    @inline(__always)
    static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        guard isRequested, signposter.isEnabled else { return nil }
        return signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    @inline(__always)
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?) {
        guard let state else { return }
        signposter.endInterval(name, state)
    }

    /// Instruments' event occurrence counts expose repeated work without a second
    /// counter store, console output on the scroll path, or observable UI updates.
    @inline(__always)
    static func event(_ name: StaticString, count: Int = 1) {
        guard isRequested, signposter.isEnabled else { return }
        signposter.emitEvent(name, "count=\(count, privacy: .public)")
    }
}
