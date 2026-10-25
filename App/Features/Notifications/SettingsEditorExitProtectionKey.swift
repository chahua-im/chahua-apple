import SwiftUI

/// Outer Settings controls must not bypass an editor's unsaved changes or in-flight save.
struct SettingsEditorExitProtectionKey: PreferenceKey {
    static var defaultValue: Bool { false }

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
