import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Shared geometry for the adaptive chat shell and its macOS window minimum.
enum ChatSplitMetrics {
    static let splitThreshold: CGFloat = 768
    static let initialSidebarWidth: CGFloat = 380
    static let minimumSidebarWidth: CGFloat = 380
    static let maximumSidebarWidth: CGFloat = 500
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
                            // Keep the native title-bar controls in AppKit's ownership.
                            // The sidebar only reserves space beneath their overlay.
                            Color.clear.frame(height: 52)
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
                .onChange(of: isResizing) { _, resizing in
                    // Gesture state also resets when SwiftUI cancels the drag.
                    if !resizing { dragStartWidth = nil }
                }
            #endif
            .onChange(of: isSplit) { _, split in
                if !split { dragStartWidth = nil }
            }
        }
        #if os(macOS)
            .ignoresSafeArea(.container, edges: .top)
        #endif
        .background(ChahuaTheme.conversationBackground(for: colorScheme))
    }

    private func pane<Content: View>(_ content: Content, width: CGFloat, isVisible: Bool)
        -> some View
    {
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
                    #if os(macOS)
                        // SwiftUI's drag gesture does not expose a cursor affordance.
                        // AppKit supplies the standard horizontal-resize cursor for this
                        // macOS-only draggable hit area.
                        .onHover { hovering in
                            (hovering ? NSCursor.resizeLeftRight : .arrow).set()
                        }
                    #endif
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
                preferredSidebarWidth = clampedSidebarWidth(
                    startWidth + value.translation.width, availableWidth: availableWidth)
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
struct ChatFloatingHeader<Avatar: View>: View {
    let title: String
    var subtitle: String?
    var isMuted = false
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenInfo: (() -> Void)?
    /// Search lives on the info page; the header only binds ⌘F, with no visible button.
    var onSearch: (() -> Void)?
    /// The phone header splits the identity and trailing controls into separate toolbar items.
    var part: Part = .full
    @ViewBuilder var avatar: () -> Avatar

    enum Part { case full, identity, trailing }

    var body: some View {
        switch part {
        case .identity:
            identity
        case .trailing:
            trailingControls
                .background { searchShortcut }
        case .full:
            #if os(macOS)
                HStack(spacing: 8) {
                    navigationControl
                    identity
                    trailingControls
                }
                .frame(maxWidth: .infinity)
                .background { searchShortcut }
            #else
                ZStack {
                    // Symmetric insets keep the identity centered between edge controls.
                    identity
                        .padding(.horizontal, 52)
                    HStack {
                        navigationControl
                        Spacer(minLength: 0)
                        trailingControls
                    }
                }
                .background { searchShortcut }
            #endif
        }
    }

    @ViewBuilder
    private var identity: some View {
        if let onOpenInfo {
            Button(action: onOpenInfo) { identityLabel }
                .buttonStyle(.plain)
                .accessibilityHint("Open chat information")
                .accessibilityIdentifier("group-info-button")
        } else {
            identityLabel
        }
    }

    private var identityLabel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                if isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Muted")
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        #if os(macOS)
            .frame(maxWidth: .infinity)
        #endif
        .contentShape(Capsule())
        .modifier(ChatGlassSurface(cornerRadius: 24, isInteractive: onOpenInfo != nil))
    }

    @ViewBuilder
    private var trailingControls: some View {
        if let onOpenInfo {
            Button(action: onOpenInfo) { avatarLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Open chat information"))
                .accessibilityIdentifier("group-info-avatar-button")
        } else {
            avatarLabel
        }
    }

    /// A circular glass control matching the back button; the avatar fills it
    /// with a thin glass rim, like Telegram's title-bar avatar.
    private var avatarLabel: some View {
        avatar()
            .frame(width: Self.avatarDiameter, height: Self.avatarDiameter)
            .clipShape(Circle())
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: onOpenInfo != nil))
            .clipShape(Circle())
            .accessibilityHidden(onOpenInfo == nil)
    }

    /// Avatar diameter inside the 44 pt glass circle; callers size their avatar to this.
    static var avatarDiameter: CGFloat { 38 }

    /// ⌘F stays available even when search has no visible header button.
    @ViewBuilder
    private var searchShortcut: some View {
        if let onSearch {
            Button("Search messages", action: onSearch)
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var navigationControl: some View {
        if let onBack {
            headerControl(
                action: onBack, systemImage: "chevron.backward", accessibilityLabel: "Back")
        } else if let onClose {
            headerControl(
                action: onClose, systemImage: "xmark", accessibilityLabel: "Close conversation")
        }
    }

    @ViewBuilder
    private func headerControl(
        action: @escaping () -> Void, systemImage: String, accessibilityLabel: String
    ) -> some View {
        let label = Image(systemName: systemImage)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 44, height: 44)
            // Plain buttons must hit-test the full control, not just the symbol.
            .contentShape(Rectangle())
        #if os(macOS)
            if #available(macOS 26, *) {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .buttonSizing(.flexible)
                .frame(width: 44, height: 44)
                .accessibilityLabel(accessibilityLabel)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.plain)
                    .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: true))
                    .accessibilityLabel(accessibilityLabel)
            }
        #else
            Button(action: action) { label }
                .buttonStyle(.plain)
                .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: true))
                .accessibilityLabel(accessibilityLabel)
        #endif
    }
}

#if os(iOS)
    /// Keep native back navigation, but let messages scroll beneath the glass controls.
    /// The title bar's safe area becomes scroll breathing room, not an opaque layout band.
    struct ChatPhoneDetailHeader<Avatar: View>: ViewModifier {
        let title: String
        var subtitle: String?
        var isMuted = false
        var onOpenInfo: (() -> Void)?
        var onSearch: (() -> Void)?
        @ViewBuilder var avatar: () -> Avatar

        func body(content: Content) -> some View {
            GeometryReader { geometry in
                content
                    .environment(\.chatHeaderInset, geometry.safeAreaInsets.top + 12)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                // iOS 26 wraps bar items in a shared glass capsule; the header draws
                // its own glass, so hide the system one to keep the avatar circular.
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .principal) {
                        header(.identity)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .topBarTrailing) {
                        header(.trailing)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) {
                        header(.identity)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        header(.trailing)
                    }
                }
            }
        }

        private func header(_ part: ChatFloatingHeader<Avatar>.Part) -> some View {
            ChatFloatingHeader(
                title: title, subtitle: subtitle, isMuted: isMuted,
                onOpenInfo: onOpenInfo, onSearch: onSearch, part: part, avatar: avatar)
        }
    }
#endif

struct ChatGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    var isInteractive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, iOS 26, *) {
            content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        } else {
            // TODO: Design dedicated title-bar/tab chrome for iOS versions without
            // Liquid Glass. Retain this functional material fallback until then.
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
    var isVisible = true
    @ViewBuilder let header: () -> Header
    @State private var headerHeight: CGFloat = 0

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .environment(\.chatHeaderInset, isVisible ? headerHeight + 12 : 0)
                .overlay(alignment: .top) {
                    if isVisible {
                        header()
                            .frame(maxWidth: .infinity)
                            .background {
                                GeometryReader { headerGeometry in
                                    Color.clear
                                        .onAppear { headerHeight = headerGeometry.size.height }
                                        .onChange(of: headerGeometry.size.height) { _, height in
                                            headerHeight = height
                                        }
                                }
                            }
                            .background(alignment: .top) {
                                ChatHeaderBackdrop()
                                    .frame(height: headerHeight + geometry.safeAreaInsets.top + 32)
                                    .offset(y: -geometry.safeAreaInsets.top)
                            }
                    }
                }
        }
    }
}

/// Very light title-bar backdrop, like Telegram for Mac: content stays visible
/// behind the glass controls, softened slightly more toward the top edge.
///
/// SwiftUI has no variable-radius blur, and a single material faded by an opacity
/// mask shows where blurred content meets sharp content. Two faint, staggered
/// material layers make the softening ramp up instead of ending at a line.
struct ChatHeaderBackdrop: View {
    private static let reaches: [Double] = [1, 0.55]

    var body: some View {
        ZStack {
            ForEach(Self.reaches, id: \.self) { reach in
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.5)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .clear, location: reach),
                            ],
                            startPoint: .top, endPoint: .bottom)
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
