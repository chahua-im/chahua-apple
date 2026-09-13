#if os(iOS)
import SwiftUI

/// A non-hit-testing marker scopes context gestures to the bubble surface.
/// iOS shares the row's touch decision; macOS retains native context monitoring.
struct MessageContextSource: ViewModifier {
    var open: ((CGRect) -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let open {
            content.background {
                GeometryReader { _ in
                        MessageBubbleHoldSource(open: open)
                            .accessibilityHidden(true)
                }
            }
            .accessibilityAction(named: Text("Message actions")) { open(.zero) }
        } else {
            content
        }
    }
}



#endif
