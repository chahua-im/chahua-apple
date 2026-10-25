import SwiftUI

private struct OpenUserProfileKey: EnvironmentKey {
    static let defaultValue: (Int32) -> Void = { _ in }
}

private struct OpenGroupInviteKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    /// The authenticated shell presents profiles without replacing the active draft/timeline.
    var openUserProfile: (Int32) -> Void {
        get { self[OpenUserProfileKey.self] }
        set { self[OpenUserProfileKey.self] = newValue }
    }

    var openGroupInvite: (String) -> Void {
        get { self[OpenGroupInviteKey.self] }
        set { self[OpenGroupInviteKey.self] = newValue }
    }
}
