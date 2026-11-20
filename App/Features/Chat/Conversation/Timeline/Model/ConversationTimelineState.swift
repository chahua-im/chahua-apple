import ChahuaAPI
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
        case message(MessageID)
    }

    enum Edge: Equatable {
        case idle
        case loading
        case failed
    }

    enum History: Equatable {
        case notDownloaded
        case saved
        case verifiedEmpty
        case server
    }

    enum HistoryConnection: Equatable {
        case offline
        case refreshing
    }

    enum SavedEdge: Equatable {
        case more
        case section
    }

    struct Live: Equatable {
        var isPinnedToBottom = false
        var followsLatest = true
        var pendingLiveCount = 0
        var unreadCount: Int64 = 0
        var scrollsTowardNewer = false
    }

    var realtimeStatus: RealtimeConnectionStatus = .idle
    var content: Content = .idle
    var live = Live()
    var older: Edge = .idle
    var newer: Edge = .idle
    var history: History?
    var historyConnection: HistoryConnection?
    var missingOfflineMessage: MessageID?
    var olderSaved: SavedEdge?
    var newerSaved: SavedEdge?
    /// Non-blocking overlay: the last reposition that could not complete. Rows remain interactive.
    var repositionFailure: RepositionTarget?
    /// HTTP recovery failed; the previous window remains browsable.
    var reconciliationFailed = false
}
