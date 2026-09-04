import Foundation

enum TimelineScrollIntent: Equatable {
    case bottom(animated: Bool)
    case reveal(TimelineRowID, animated: Bool, highlight: Bool)
}

struct TimelineScrollRequest: Equatable {
    let id: Int
    let intent: TimelineScrollIntent
}

struct TimelineHostSnapshot {
    let revision: Int
    let windowRevision: Int
    let rows: [TimelineRow]
    let animateFollowing: Bool
    let pendingScroll: TimelineScrollRequest?
}

enum TimelineViewportChangeReason {
    case user
    case layout
    case programmatic
}

struct TimelineViewport: Equatable {
    var firstVisibleIndex: Int?
    var lastVisibleIndex: Int?
    var distanceToTop: CGFloat
    var distanceToBottom: CGFloat
    var height: CGFloat

    static let empty = TimelineViewport(
        firstVisibleIndex: nil,
        lastVisibleIndex: nil,
        distanceToTop: 0,
        distanceToBottom: 0,
        height: 0
    )

    func isValid(forRowCount count: Int) -> Bool {
        guard height > 0 else { return false }
        if count == 0 { return firstVisibleIndex == nil && lastVisibleIndex == nil }
        guard let firstVisibleIndex, let lastVisibleIndex else { return false }
        return firstVisibleIndex >= 0 && firstVisibleIndex <= lastVisibleIndex && lastVisibleIndex < count
    }
}
