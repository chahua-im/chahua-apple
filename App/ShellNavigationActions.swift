import Foundation

/// Environment closures participate in SwiftUI invalidation even through an
/// Equatable view boundary. Keep their identity stable while refreshing their
/// imperative targets; unrelated list updates must not redraw the open timeline.
@MainActor
final class ShellNavigationActions {
    var profileHandler: ((Int32) -> Void)?
    var inviteHandler: ((String) -> Void)?

    lazy var openProfile: (Int32) -> Void = { [weak self] uid in
        self?.profileHandler?(uid)
    }
    lazy var openInvite: (String) -> Void = { [weak self] code in
        self?.inviteHandler?(code)
    }

    func clear() {
        profileHandler = nil
        inviteHandler = nil
    }
}
