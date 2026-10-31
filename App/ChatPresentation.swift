import SwiftUI

/// Available-width presentation, independent of the device or operating system.
private struct WideChatPresentationKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isWideChatLayout: Bool {
        get { self[WideChatPresentationKey.self] }
        set { self[WideChatPresentationKey.self] = newValue }
    }
}
