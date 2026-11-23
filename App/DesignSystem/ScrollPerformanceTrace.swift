import Foundation
import SwiftUI
import os

/// Local Instruments diagnostics, available in optimized builds. No timers, frame-rate
/// overrides, or user content; disabled launches do not initialize the signposter.
nonisolated enum ScrollPerformanceTrace {
    static let tracksInvalidations =
        ProcessInfo.processInfo.arguments.contains("-invalidation-profiling")
    static let isRequested =
        tracksInvalidations
        || ProcessInfo.processInfo.arguments.contains("-scroll-profiling")
        || ProcessInfo.processInfo.environment["CHAHUA_SCROLL_PROFILING"] == "1"
    private static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "app.chahua.chat", category: .pointsOfInterest))

    /// Body evaluation is a consumer, not necessarily the invalidation source.
    /// Keep property-change reasons opt-in: logging them can perturb a scroll trace.
    @MainActor
    static func logChanges<V: View>(_ view: V.Type) {
        guard tracksInvalidations else { return }
        if #available(iOS 17.1, macOS 14.1, *) {
            V._logChanges()
        }
    }

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
