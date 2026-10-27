import Combine
import Foundation

/// Scroll-driven chrome has its own observation boundary. Updating a visible-message
/// date must not rebuild the conversation's composer, sheets, or interaction hosts.
@MainActor
final class TimelineViewportPresentation: ObservableObject {
    struct Value: Equatable {
        var bottomVisibleMessageDate: Date?
        var showsJumpToLatest = false
    }

    @Published private(set) var value = Value()

    func update(bottomVisibleMessageDate: Date?, showsJumpToLatest: Bool) {
        let next = Value(
            bottomVisibleMessageDate: bottomVisibleMessageDate,
            showsJumpToLatest: showsJumpToLatest)
        guard next != value else { return }
        value = next
    }
}
