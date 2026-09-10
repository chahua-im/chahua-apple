import SwiftUI

/// Row actions must defer touch activation until the shared row coordinator has
/// ruled out a hold, swipe, or scroll. SwiftUI Button owns its own touch tracking,
/// so iOS uses a non-hit-testing registration while retaining button accessibility
/// and focused keyboard activation.
/// macOS keeps its ordinary plain SwiftUI button behavior.
struct MessageRowActionButton<Label: View>: View {
    let action: () -> Void
    private let label: Label
    @Environment(\.isEnabled) private var isEnabled

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        #if os(iOS)
            label
                .background {
                    if isEnabled {
                        MessageRowTapSource(action: action)
                            .accessibilityHidden(true)
                    }
                }
                .focusable(isEnabled)
                .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                    guard isEnabled else { return .ignored }
                    action()
                    return .handled
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    if isEnabled { action() }
                }
        #else
            Button(action: action) { label }
                .buttonStyle(.plain)
        #endif
    }
}
