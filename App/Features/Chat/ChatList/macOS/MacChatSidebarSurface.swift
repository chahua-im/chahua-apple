#if os(macOS)
    import SwiftUI

    /// M5/M6 dock the sidebar against the window edges. Keep native backdrop blur,
    /// but draw only the trailing divider: no inset card, rounded corners or shadow.
    struct MacChatSidebarSurface: ViewModifier {
        let isSplit: Bool
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            let dark = colorScheme == .dark
            content
                .background {
                    Rectangle().fill(.ultraThinMaterial)
                        .overlay {
                            Rectangle().fill(
                                dark
                                    ? Color(white: 0.12).opacity(0.92)
                                    : Color(
                                        .sRGB, red: 244 / 255, green: 244 / 255,
                                        blue: 247 / 255, opacity: 0.92))
                        }
                }
                .overlay(alignment: .trailing) {
                    if isSplit {
                        Rectangle()
                            .fill(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.16))
                            .frame(width: 0.5)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
#endif
