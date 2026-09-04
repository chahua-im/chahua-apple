import Foundation

struct ConversationTimelineState: Equatable {
    /// Lifecycle only. Failures that leave the timeline browsable live in `repositionFailure`.
    enum Content: Equatable {
        case idle
        case loadingInitial
        case initialLoadFailed
        case ready
        case repositioning(RepositionTarget)
    }

    enum RepositionTarget: Equatable {
        case liveEdge
        case message(String)
    }

    enum Edge: Equatable {
        case idle
        case loading
        case failed
    }

    struct Live: Equatable {
        var isPinnedToBottom = false
        var followsLatest = true
        var unseenCount = 0
    }

    var content: Content = .idle
    var live = Live()
    var older: Edge = .idle
    var newer: Edge = .idle
    /// Non-blocking overlay: the last reposition that could not complete. Rows remain interactive.
    var repositionFailure: RepositionTarget?
}
