#if os(macOS)
    import AppKit
    import SwiftUI

    /// Keep AppKit's transparent title band and native window buttons alive.
    /// Sidebar actions stay in content so full-window overlays cover them.
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
                Color.clear.frame(width: 1, height: Self.titleBandHeight)
                    .accessibilityHidden(true)
            }
        }
    }

    extension Scene {
        func conversationWindowDefaults() -> some Scene {
            // Use the macOS 14-compatible default-size API. This never resizes
            // an attached window or overrides a restored frame.
            let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
            return self.defaultSize(
                width: min(1280, available.width), height: min(800, available.height))
        }
    }
#endif
