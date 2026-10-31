#if os(macOS)
    import SwiftUI

    /// Keep one native toolbar alive for the lifetime of the main window. AppKit owns
    /// traffic-light geometry; no content view moves, hides, or replaces those buttons.
    struct MacConversationWindowChrome: ViewModifier {
        static let titleBandHeight: CGFloat = 52

        func body(content: Content) -> some View {
            content
                .toolbar {
                    if #available(macOS 26, *) {
                        titleBand.sharedBackgroundVisibility(.hidden)
                    } else {
                        titleBand
                    }
                }
                .toolbarBackground(.hidden, for: .windowToolbar)
        }

        private var titleBand: some ToolbarContent {
            ToolbarItem(id: "chahua-window-titleband", placement: .principal) {
                // Unified AppKit toolbars keep a 52pt native band regardless of taller
                // custom-item requests. Preserve their native traffic-light geometry;
                // stretching or reparenting those controls is unsafe during navigation.
                Color.clear.frame(width: 1, height: Self.titleBandHeight)
                    .accessibilityHidden(true)
            }
        }
    }
#endif
