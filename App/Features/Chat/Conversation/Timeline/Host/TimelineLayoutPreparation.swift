import ChahuaAPI
import Foundation

/// Geometry work only. Native hosts retain their own transaction and scroll ownership.
@MainActor
final class TimelineLayoutPreparation {
    let snapshot: TimelineHostSnapshot
    let environment: TimelineLayoutEnvironment
    let profile: MeResponse?
    private var nextIndex = 0
    private(set) var presentations: [TimelineRowID: TimelineRowPresentation] = [:]
    private(set) var layouts: [TimelineRowID: TimelineRowLayout] = [:]

    init(snapshot: TimelineHostSnapshot, environment: TimelineLayoutEnvironment, profile: MeResponse?) {
        self.snapshot = snapshot
        self.environment = environment
        self.profile = profile
        presentations.reserveCapacity(snapshot.rows.count)
        layouts.reserveCapacity(snapshot.rows.count)
    }

    func advance(cache: TimelineLayoutCache, currentUserID: Int32?, isThreadTimeline: Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.004
        let end = min(snapshot.rows.count, nextIndex + 32)
        while nextIndex < end {
            let row = snapshot.rows[nextIndex]
            let presentation = TimelineRowPresentation.make(row: row, currentUserProfile: profile, currentUserID: currentUserID, isThreadTimeline: isThreadTimeline, environment: environment)
            presentations[row.id] = presentation
            layouts[row.id] = cache.layout(for: presentation, environment: environment)
            nextIndex += 1
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
        }
        return nextIndex == snapshot.rows.count
    }
}
