#if os(macOS)
    import SwiftUI

    /// Match the desktop artboard's restrained glass instead of the OS-version-
    /// dependent Liquid Glass lens. SwiftUI material supplies native backdrop blur;
    /// explicit tint, hairlines and shadow supply the reference's surface treatment.
    struct MacChatGlassSurface: ViewModifier {
        let cornerRadius: CGFloat
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let dark = colorScheme == .dark
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                        .overlay {
                            shape.fill(
                                dark ? Color(white: 0.15).opacity(0.62) : Color.white.opacity(0.62))
                        }
                        .overlay {
                            shape.strokeBorder(.white.opacity(dark ? 0.16 : 0.90), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(dark ? 0.20 : 0.08), radius: 10, y: 6)
                }
                .overlay { shape.stroke(.black.opacity(0.06), lineWidth: 0.5) }
        }
    }
#endif
