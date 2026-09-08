import SwiftUI

/// Shared geometry for the adaptive chat shell and its macOS window minimum.
enum ChatSplitMetrics {
    static let splitThreshold: CGFloat = 768
    static let initialSidebarWidth: CGFloat = 320
    static let minimumSidebarWidth: CGFloat = 280
    static let maximumSidebarWidth: CGFloat = 400
    static let minimumDetailWidth: CGFloat = 440
    static let dividerWidth: CGFloat = 1
    static let accessibilityStep: CGFloat = 20
}

struct ChatSplitLayout<Sidebar: View, Detail: View>: View {
    let hasSelection: Bool
    private let sidebar: (Bool) -> Sidebar
    private let detail: (Bool) -> Detail

    @State private var preferredSidebarWidth = ChatSplitMetrics.initialSidebarWidth
    @State private var dragStartWidth: CGFloat?

    init(
        hasSelection: Bool,
        @ViewBuilder sidebar: @escaping (Bool) -> Sidebar,
        @ViewBuilder detail: @escaping (Bool) -> Detail
    ) {
        self.hasSelection = hasSelection
        self.sidebar = sidebar
        self.detail = detail
    }

    var body: some View {
        GeometryReader { proxy in
            let isSplit = proxy.size.width >= ChatSplitMetrics.splitThreshold
            let sidebarWidth = effectiveSidebarWidth(for: proxy.size.width)
            let detailWidth = max(0, proxy.size.width - sidebarWidth - ChatSplitMetrics.dividerWidth)

            HStack(spacing: 0) {
                pane(
                    sidebar(isSplit),
                    width: isSplit ? sidebarWidth : (hasSelection ? 0 : proxy.size.width),
                    isVisible: isSplit || !hasSelection
                )

                splitDivider(isSplit: isSplit, availableWidth: proxy.size.width)
                    .frame(width: isSplit ? ChatSplitMetrics.dividerWidth : 0)
                    .opacity(isSplit ? 1 : 0)
                    .allowsHitTesting(isSplit)
                    .accessibilityHidden(!isSplit)

                pane(
                    detail(isSplit),
                    width: isSplit ? detailWidth : (hasSelection ? proxy.size.width : 0),
                    isVisible: isSplit || hasSelection
                )
            }
            .onChange(of: isSplit) { split in
                if !split { dragStartWidth = nil }
            }
        }
    }

    private func pane<Content: View>(_ content: Content, width: CGFloat, isVisible: Bool) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(width: max(0, width), alignment: .leading)
            .clipped()
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }

    private func splitDivider(isSplit: Bool, availableWidth: CGFloat) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture(availableWidth: availableWidth))
                    .accessibilityLabel("Conversation list width")
                    .accessibilityValue("\(Int(effectiveSidebarWidth(for: availableWidth))) points")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            preferredSidebarWidth = clampedSidebarWidth(
                                preferredSidebarWidth + ChatSplitMetrics.accessibilityStep,
                                availableWidth: availableWidth
                            )
                        case .decrement:
                            preferredSidebarWidth = clampedSidebarWidth(
                                preferredSidebarWidth - ChatSplitMetrics.accessibilityStep,
                                availableWidth: availableWidth
                            )
                        @unknown default:
                            break
                        }
                    }
            }
    }

    private func resizeGesture(availableWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startWidth = dragStartWidth ?? effectiveSidebarWidth(for: availableWidth)
                if dragStartWidth == nil { dragStartWidth = startWidth }
                preferredSidebarWidth = clampedSidebarWidth(startWidth + value.translation.width, availableWidth: availableWidth)
            }
            .onEnded { _ in
                dragStartWidth = nil
            }
    }

    private func effectiveSidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        clampedSidebarWidth(preferredSidebarWidth, availableWidth: availableWidth)
    }

    private func clampedSidebarWidth(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let maximumAllowed = min(
            ChatSplitMetrics.maximumSidebarWidth,
            availableWidth - ChatSplitMetrics.minimumDetailWidth - ChatSplitMetrics.dividerWidth
        )
        return min(max(width, ChatSplitMetrics.minimumSidebarWidth), maximumAllowed)
    }
}
