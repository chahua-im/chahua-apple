import ChahuaAPI
import Combine
import Foundation

/// Native hosts measure the current unobscured viewport on demand. A queued scroll
/// report can still describe the previous frame when the user presses the button.
@MainActor
protocol TimelineSelectionViewportSource: AnyObject {
    func visibleMessageIDsForSelection() -> [MessageID]?
}

@MainActor
final class TimelineSelectionRange: ObservableObject {
    static let limit = 100

    enum Direction { case older, newer }

    struct Offer: Equatable {
        let direction: Direction
        let count: Int
        let remaining: Int

        var exceedsLimit: Bool { count > remaining }
    }

    struct Edges: Equatable {
        var older: MessageID?
        var newer: MessageID?

        subscript(_ direction: Direction) -> MessageID? {
            direction == .older ? older : newer
        }
    }

    @Published private(set) var offer: Offer?
    private(set) var direction: Direction?
    var edges = Edges()

    func updateDirection(
        for movement: Direction, previous: Edges, reachedEdge: Bool,
        canExtend: (Direction, MessageID?) -> Bool
    ) {
        guard movement != direction else { return }
        guard let direction, canExtend(direction, edges[direction]) else {
            self.direction = movement
            return
        }
        let target = edges[movement]
        let farther =
            target.map { id in
                previous[movement].map { movement == .older ? id < $0 : id > $0 } ?? true
            } ?? false
        if (farther || reachedEdge) && canExtend(movement, target) {
            self.direction = movement
        }
    }

    func present(_ next: Offer?) {
        if next != offer { offer = next }
    }

    func clearDirection() {
        direction = nil
        present(nil)
    }
}
