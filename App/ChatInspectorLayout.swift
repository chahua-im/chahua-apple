import SwiftUI

/// The inspector consumes detail space; it never changes the window's minimum or size.
/// A sheet preserves access when the current detail cannot fit both readable columns.
struct ChatInspectorLayout<Detail: View, Inspector: View>: View {
    @Binding var isPresented: Bool
    var freezesPresentation = false
    /// Message search stays beside the timeline, even when the detail is too narrow
    /// to reserve a column. Chat Info retains its existing modal fallback.
    var overlaysWhenNarrow = false
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var inspector: () -> Inspector
    @State private var presentedInline: Bool?
    @State private var fitsInline = false

    static var inspectorWidth: CGFloat { 340 }
    static var gap: CGFloat {
        #if os(macOS)
            0
        #else
            12
        #endif
    }

    var body: some View {
        let presentsInline = presentedInline ?? fitsInline
        HStack(spacing: Self.gap) {
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented && presentsInline {
                inspector()
                    .environment(\.chatInfoIsModal, false)
                    .voicePlaybackCovered(true)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .voicePlaybackCovered(isPresented && !presentsInline && !overlaysWhenNarrow)
        .overlay(alignment: .trailing) {
            if isPresented && !presentsInline && overlaysWhenNarrow {
                inspector()
                    .environment(\.chatInfoIsModal, false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(maxWidth: Self.inspectorWidth)
                    #if os(macOS)
                        .modifier(MacChatInfoSurface())
                    #else
                        .background(.background)
                    #endif
                    .padding(.trailing, ChatSplitMetrics.outerInset)
                    .padding(.vertical, ChatSplitMetrics.outerInset)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Content depends on the presentation breakpoint, not on each pixel of width.
        .onGeometryChange(for: Bool.self) {
            $0.size.width >= ChatSplitMetrics.minimumDetailWidth
                + Self.inspectorWidth + Self.gap + ChatSplitMetrics.outerInset
        } action: { value in
            fitsInline = value
            if presentedInline == nil || !freezesPresentation { presentedInline = value }
        }
        .onChange(of: freezesPresentation) { _, frozen in
            if !frozen { presentedInline = fitsInline }
        }
        .sheet(
            isPresented: Binding(
                // Do not open a sheet before the first width measurement is available.
                get: { isPresented && presentedInline == false && !overlaysWhenNarrow },
                set: {
                    if !$0 && !presentsInline && !overlaysWhenNarrow { isPresented = false }
                }
            )
        ) {
            inspector()
                .environment(\.isVoicePlaybackHeaderCovered, false)
                .environment(\.chatInfoIsModal, true)
                .modifier(ChatInfoModalSizing())
                .interactiveDismissDisabled(freezesPresentation)
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
