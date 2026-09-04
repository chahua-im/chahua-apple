import Foundation

enum TimelineChange: Equatable {
    case reset
    case incremental(removals: IndexSet, insertions: IndexSet, reloads: IndexSet)

    static func compute(from old: [TimelineRow], to new: [TimelineRow]) -> TimelineChange {
        let difference = new.map(\.id).difference(from: old.map(\.id))
        let removals = IndexSet(difference.removals.map(Self.offset(of:)))
        let insertions = IndexSet(difference.insertions.map(Self.offset(of:)))
        let oldRowsByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let reloads = IndexSet(new.indices.filter { index in
            guard let oldRow = oldRowsByID[new[index].id] else { return false }
            return oldRow != new[index]
        })
        return .incremental(removals: removals, insertions: insertions, reloads: reloads)
    }

    nonisolated private static func offset(of change: CollectionDifference<TimelineRowID>.Change) -> Int {
        switch change {
        case .remove(let offset, _, _), .insert(let offset, _, _):
            offset
        }
    }

    var isEmpty: Bool {
        guard case let .incremental(removals, insertions, reloads) = self else { return false }
        return removals.isEmpty && insertions.isEmpty && reloads.isEmpty
    }
}
