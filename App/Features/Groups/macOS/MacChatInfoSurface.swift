#if os(macOS)
    import SwiftUI

    /// M6 keeps the info panel floating while the conversation sidebar is docked.
    /// Native material supplies backdrop blur without an OS-dependent glass lens;
    /// the panel owns its tint, outline and shadow independently of its contents.
    struct MacChatInfoSurface: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: 16)
            let dark = colorScheme == .dark
            content
                .clipShape(shape)
                .background {
                    shape.fill(.ultraThinMaterial)
                        .overlay {
                            shape.fill(
                                dark
                                    ? Color(white: 0.12).opacity(0.90)
                                    : Color(
                                        .sRGB, red: 246 / 255, green: 246 / 255,
                                        blue: 249 / 255, opacity: 0.90))
                        }
                        .shadow(color: .black.opacity(dark ? 0.24 : 0.10), radius: 12, y: 6)
                }
                .overlay {
                    shape.strokeBorder(
                        dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10),
                        lineWidth: 0.5)
                }
        }
    }
#endif
