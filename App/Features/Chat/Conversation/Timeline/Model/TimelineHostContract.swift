import Foundation

enum TimelineScrollIntent: Equatable {
    case preserveAnchor
    case bottom(animated: Bool)
    case reveal(TimelineRowID, animated: Bool, highlight: Bool)
}

struct TimelineHostUpdate {
    let rows: [TimelineRow]
    let change: TimelineChange
    let scroll: TimelineScrollIntent
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
}
