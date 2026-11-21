#if os(macOS)
    import SwiftUI

    /// SwiftUI's automatic Back lives in the window toolbar, not the detail pane.
    /// Reuse the thread's SwiftUI header and dismiss only this navigation level.
    struct MacForwardedRecordsHeader: ViewModifier {
        @Environment(\.dismiss) private var dismiss

        func body(content: Content) -> some View {
            content
                .navigationTitle("")
                .navigationBarBackButtonHidden(true)
                .modifier(
                    ChatHeaderOverlay {
                        ChatFloatingHeader(
                            title: AppLanguage.localized("Forwarded Messages"),
                            onBack: { dismiss() }
                        ) {
                            Image(systemName: "arrowshape.turn.up.right.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                    })
        }
    }
#endif
