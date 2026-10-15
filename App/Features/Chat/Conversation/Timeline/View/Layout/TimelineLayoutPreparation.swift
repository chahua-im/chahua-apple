import Foundation

/// Prepares one snapshot's rows. Native hosts retain their own transaction and scroll ownership.
///
/// Rows the cache already holds for this environment are reused when the preparation
/// is created; only new or changed rows are built. A few changes (an append, an edit,
/// a reaction) complete in one display turn; larger batches (opening, paging, resizing)
/// yield after 4 ms so no frame blocks. Built rows land in the shared cache, so a
/// preparation superseded by a newer revision does not lose its work.
@MainActor
final class TimelineLayoutPreparation {
    static let sameTurnLimit = 8

    let snapshot: TimelineHostSnapshot
    let environment: TimelineLayoutEnvironment
    private(set) var rows: [TimelineRowID: PreparedRow] = [:]
    private var changed: [Int] = []
    private var nextChanged = 0

    init(
        snapshot: TimelineHostSnapshot, environment: TimelineLayoutEnvironment,
        cache: TimelineRowCache
    ) {
        self.snapshot = snapshot
        self.environment = environment
        rows.reserveCapacity(snapshot.rows.count)
        for (index, row) in snapshot.rows.enumerated() {
            if let entry = cache.current(row, environment: environment) {
                rows[row.id] = entry
            } else {
                changed.append(index)
            }
        }
    }

    func advance(cache: TimelineRowCache) -> Bool {
        let budgeted = changed.count > Self.sameTurnLimit
        let deadline = ProcessInfo.processInfo.systemUptime + 0.004
        while nextChanged < changed.count {
            let row = snapshot.rows[changed[nextChanged]]
            rows[row.id] = cache.prepared(row, environment: environment)
            nextChanged += 1
            if budgeted, ProcessInfo.processInfo.systemUptime >= deadline { break }
        }
        return nextChanged == changed.count
    }
}
