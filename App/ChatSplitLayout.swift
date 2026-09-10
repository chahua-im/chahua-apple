import SwiftUI

/// Shared geometry for the adaptive chat shell and its macOS window minimum.
enum ChatSplitMetrics {
    static let splitThreshold: CGFloat = 768
    static let initialSidebarWidth: CGFloat = 320
    static let minimumSidebarWidth: CGFloat = 280
    static let maximumSidebarWidth: CGFloat = 400
    static let minimumDetailWidth: CGFloat = 440
    static let dividerWidth: CGFloat = 1
    static let outerInset: CGFloat = 12
    static let accessibilityStep: CGFloat = 20
}

#if os(macOS)
private struct ChatSplitResizingKey: EnvironmentKey {
    nonisolated static let defaultValue = false
}

extension EnvironmentValues {
    var isChatSplitResizing: Bool {
        get { self[ChatSplitResizingKey.self] }
        set { self[ChatSplitResizingKey.self] = newValue }
    }
}
#endif

struct ChatSplitLayout<Sidebar: View, Detail: View>: View {
    let hasSelection: Bool
    private let sidebar: (Bool) -> Sidebar
    private let detail: (Bool) -> Detail

    @Environment(\.colorScheme) private var colorScheme
    @State private var preferredSidebarWidth = ChatSplitMetrics.initialSidebarWidth
    @State private var dragStartWidth: CGFloat?
    #if os(macOS)
    @GestureState private var isResizing = false
    #endif

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
            let availableWidth = proxy.size.width
            let sidebarWidth = effectiveSidebarWidth(for: availableWidth)
            let detailWidth = max(0, availableWidth - sidebarWidth - ChatSplitMetrics.dividerWidth)

            HStack(spacing: 0) {
                pane(
                    VStack(spacing: 0) {
                        #if os(macOS)
                        SidebarWindowControls()
                            .frame(height: 52)
                        #endif
                        sidebar(isSplit)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial),
                    width: isSplit ? sidebarWidth : (hasSelection ? 0 : proxy.size.width),
                    isVisible: isSplit || !hasSelection
                )

                splitDivider(isSplit: isSplit, availableWidth: availableWidth)
                    .frame(width: isSplit ? ChatSplitMetrics.dividerWidth : 0)
                    .opacity(isSplit ? 1 : 0)
                    .allowsHitTesting(isSplit)
                    .accessibilityHidden(!isSplit)
                    .zIndex(1)

                pane(
                    detail(isSplit),
                    width: isSplit ? detailWidth : (hasSelection ? proxy.size.width : 0),
                    isVisible: isSplit || hasSelection
                )
            }
            #if os(macOS)
            .environment(\.isChatSplitResizing, isSplit && isResizing)
            .onChange(of: isResizing) { resizing in
                // Gesture state also resets when SwiftUI cancels the drag.
                if !resizing { dragStartWidth = nil }
            }
            #endif
            .onChange(of: isSplit) { split in
                if !split { dragStartWidth = nil }
            }
        }
        #if os(macOS)
        .ignoresSafeArea(.container, edges: .top)
        #endif
        .background(ChahuaTheme.conversationBackground(for: colorScheme))
    }

    private func pane<Content: View>(_ content: Content, width: CGFloat, isVisible: Bool) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(width: max(0, width), alignment: .leading)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }

    private func splitDivider(isSplit: Bool, availableWidth: CGFloat) -> some View {
        Color.primary.opacity(0.12)
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
        // The divider moves with the sidebar. Its local coordinates feed that
        // movement back into translation, so measure the pointer in a fixed space.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            #if os(macOS)
            .updating($isResizing) { _, resizing, _ in resizing = true }
            #endif
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

/// In-content chrome shared by the adaptive conversation and its diagnostic surface.
struct ChatFloatingHeader: View {
    let title: String
    var avatarURL: URL?
    var showsAvatar = true
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Label("Chats", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }
            if showsAvatar {
                AvatarView(url: avatarURL, displayName: title, diameter: 32)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 42)
        .modifier(ChatGlassSurface(cornerRadius: 24))
    }
}

struct ChatGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    var isInteractive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, iOS 26, *) {
            content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(0.08)) }
        }
    }
}

private struct ChatHeaderInsetKey: EnvironmentKey {
    nonisolated static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var chatHeaderInset: CGFloat {
        get { self[ChatHeaderInsetKey.self] }
        set { self[ChatHeaderInsetKey.self] = newValue }
    }
}

/// Reserve scrollable breathing room, not layout space: rows travel behind the glass.
struct ChatHeaderOverlay<Header: View>: ViewModifier {
    @ViewBuilder let header: () -> Header
    @State private var headerHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.chatHeaderInset, headerHeight + 12)
            .overlay(alignment: .top) {
                header()
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { headerHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { headerHeight = $0 }
                        }
                    }
            }
    }
}
