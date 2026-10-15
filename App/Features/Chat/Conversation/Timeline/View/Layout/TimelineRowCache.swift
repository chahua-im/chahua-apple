import Foundation

/// One row's presentation and geometry for one layout environment. A reference type
/// so hosts and preparations share prepared rows without copying presentations.
@MainActor
final class PreparedRow {
    let row: TimelineRow
    let presentation: TimelineRowPresentation
    let layout: TimelineRowLayout
    var environment: TimelineLayoutEnvironment { presentation.environment }

    init(row: TimelineRow, presentation: TimelineRowPresentation, layout: TimelineRowLayout) {
        self.row = row
        self.presentation = presentation
        self.layout = layout
    }
}

/// Prepared rows by identity, shared by a host's preparations and on-demand measurement.
///
/// `TimelineRowPresentation.make` is pure in the row value and environment, so an entry
/// stays valid until either changes: an append rebuilds the new row and any neighbor
/// whose grouping changed, not the whole timeline. Geometry is additionally reused when
/// a rebuilt presentation keeps its layout key.
@MainActor
final class TimelineRowCache {
    private let geometry = TimelineLayoutCache()
    private let currentUserID: Int32?
    private let isThreadTimeline: Bool
    private var entries: [TimelineRowID: PreparedRow] = [:]

    init(currentUserID: Int32?, isThreadTimeline: Bool) {
        self.currentUserID = currentUserID
        self.isThreadTimeline = isThreadTimeline
    }

    /// The stored entry if it is still exact for `row` in `environment`.
    func current(_ row: TimelineRow, environment: TimelineLayoutEnvironment) -> PreparedRow? {
        guard let entry = entries[row.id], entry.environment == environment, entry.row == row
        else { return nil }
        return entry
    }

    func prepared(_ row: TimelineRow, environment: TimelineLayoutEnvironment) -> PreparedRow {
        if let entry = current(row, environment: environment) { return entry }
        let presentation = TimelineRowPresentation.make(
            row: row, currentUserID: currentUserID, isThreadTimeline: isThreadTimeline,
            environment: environment)
        let entry = PreparedRow(
            row: row, presentation: presentation,
            layout: geometry.layout(for: presentation, environment: environment))
        // Without a measurable width the layout is a placeholder; never reuse it.
        if environment.timelineWidth.isFinite, environment.timelineWidth > 0 {
            entries[row.id] = entry
        }
        return entry
    }

    func remove(_ ids: Set<TimelineRowID>) {
        for id in ids { entries.removeValue(forKey: id) }
        geometry.remove(ids)
    }
}
