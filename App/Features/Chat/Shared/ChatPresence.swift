import Foundation

/// The mounted UI consumers share one replaceable socket watch. Keep its wire
/// scope deterministic and within the server's 100-user / 4-group limits.
struct PresenceScope: Equatable {
    var userIDs: [Int32] = []
    var chatIDs: [String] = []

    var isEmpty: Bool { userIDs.isEmpty && chatIDs.isEmpty }

    static func combined(_ scopes: some Sequence<PresenceScope>) -> PresenceScope {
        var users = Set<Int32>()
        var groups = Set<String>()
        for scope in scopes {
            users.formUnion(scope.userIDs)
            groups.formUnion(scope.chatIDs)
        }
        return PresenceScope(
            userIDs: Array(users.sorted().prefix(100)),
            chatIDs: Array(groups.sorted().prefix(4)))
    }
}
