import SwiftUI

/// The inspector consumes detail space; it never changes the window's minimum or size.
/// A sheet preserves access when the current detail cannot fit both readable columns.
struct ChatInspectorLayout<Detail: View, Inspector: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var inspector: () -> Inspector

    static var inspectorWidth: CGFloat { 340 }
    static var gap: CGFloat {
        #if os(macOS)
            0
        #else
            12
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let fitsInline =
                geometry.size.width >= ChatSplitMetrics.minimumDetailWidth
                + Self.inspectorWidth + Self.gap + ChatSplitMetrics.outerInset
            HStack(spacing: Self.gap) {
                detail()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isPresented && fitsInline {
                    inspector()
                        .frame(width: Self.inspectorWidth)
                        #if os(macOS)
                            .modifier(MacChatInfoSurface())
                        #else
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        #endif
                        .padding(.trailing, ChatSplitMetrics.outerInset)
                        .padding(.vertical, ChatSplitMetrics.outerInset)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { isPresented && !fitsInline },
                    set: { if !$0 { isPresented = false } }
                )
            ) {
                inspector()
                    .frame(minWidth: 320, idealWidth: Self.inspectorWidth, minHeight: 420)
            }
        }
    }
}
