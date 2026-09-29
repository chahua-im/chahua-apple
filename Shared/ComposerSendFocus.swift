import SwiftUI

struct ComposerSendFocus: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
            // Send must not take keyboard focus from the editor on mouse clicks.
            content.focusable(false)
        #else
            content
        #endif
    }
}
