import Foundation

@MainActor
final class TimelineLayoutCache {
    private struct Entry {
        let key: RowLayoutKey
        let environment: TimelineLayoutEnvironment
        let layout: TimelineRowLayout
    }

    private let engine = TimelineLayoutEngine()
    private var entries: [TimelineRowID: Entry] = [:]
    private(set) var missCount = 0

    func layout(for content: TimelineRowPresentation, environment: TimelineLayoutEnvironment) -> TimelineRowLayout {
        guard environment.timelineWidth.isFinite, environment.timelineWidth > 0 else { return .empty }
        if let layout = cachedLayout(for: content.row.id, key: content.layoutKey, environment: environment) { return layout }
        missCount += 1
        let layout = engine.layout(content, environment: environment)
        entries[content.row.id] = .init(key: content.layoutKey, environment: environment, layout: layout)
        return layout
    }

    func cachedLayout(for id: TimelineRowID, key: RowLayoutKey, environment: TimelineLayoutEnvironment) -> TimelineRowLayout? {
        guard let entry = entries[id], entry.key == key, entry.environment == environment else { return nil }
        return entry.layout
    }


    func remove(_ ids: Set<TimelineRowID>) {
        for id in ids { entries.removeValue(forKey: id) }
    }

    func removeAll() { entries.removeAll(keepingCapacity: true) }
}
