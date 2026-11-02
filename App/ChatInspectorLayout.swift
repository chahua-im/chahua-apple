import SwiftUI

/// The inspector consumes detail space; it never changes the window's minimum or size.
/// A sheet preserves access when the current detail cannot fit both readable columns.
struct ChatInspectorLayout<Detail: View, Inspector: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var inspector: () -> Inspector
    @State private var inlineEligible = false

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
                        .environment(\.chatInfoIsModal, false)
                        .frame(width: Self.inspectorWidth)
                        #if os(macOS)
                            .modifier(MacChatInfoSurface())
                        #else
                            .background(.background)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        #endif
                        .padding(.trailing, ChatSplitMetrics.outerInset)
                        .padding(.vertical, ChatSplitMetrics.outerInset)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onChange(of: fitsInline, initial: true) { _, value in
                inlineEligible = value
            }
            .sheet(
                isPresented: Binding(
                    get: { isPresented && !fitsInline },
                    set: { if !$0 && !inlineEligible { isPresented = false } }
                )
            ) {
                inspector()
                    .environment(\.chatInfoIsModal, true)
                    .modifier(ChatInfoModalSizing())
            }
        }
    }
}

private struct ChatInfoModalSizing: ViewModifier {
    private var idealWidth: CGFloat {
        #if os(macOS)
            380
        #else
            480
        #endif
    }
    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content
                .frame(
                    minWidth: 320, idealWidth: idealWidth, maxWidth: 520,
                    minHeight: 420, idealHeight: 560, maxHeight: 760
                )
                .presentationSizing(.fitted)
                .presentationCornerRadius(20)
        } else {
            content.frame(minWidth: 320, idealWidth: idealWidth, minHeight: 420, idealHeight: 560)
                .presentationCornerRadius(20)
        }
    }
}

private struct ChatInfoModalKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatInfoIsModal: Bool {
        get { self[ChatInfoModalKey.self] }
        set { self[ChatInfoModalKey.self] = newValue }
    }
}
