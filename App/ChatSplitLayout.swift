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
    /// The trailing slot holds its own control (e.g. the thread subscription menu)
    /// rather than a decorative avatar.
    var trailingIsControl = false
    /// Unread count shown beside the back chevron, like the app-icon badge; 0 hides it.
    var backBadgeCount = 0
    @ViewBuilder var avatar: () -> Avatar

    var body: some View {
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
                    .padding(.horizontal, backBadgeCount > 0 ? 92 : 52)
                HStack {
                    navigationControl
                    Spacer(minLength: 0)
                    trailingControls
                }
            }
            .background { searchShortcut }
        #endif
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

    /// Built like `headerControl`: the glass wraps the button rather than sitting inside
    /// its label, and is not clipped, so the interactive glass can bulge and highlight
    /// on press instead of the touch landing on a flat, clipped avatar image.
    private var trailingControls: some View {
        let isInteractive = onOpenInfo != nil || trailingIsControl
        return Group {
            if let onOpenInfo {
                Button(action: onOpenInfo) { avatarCircle }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Open chat information"))
                    .accessibilityIdentifier("group-info-avatar-button")
            } else {
                avatarCircle
                    .accessibilityHidden(!isInteractive)
            }
        }
        .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: isInteractive))
    }

    /// The avatar centered in the 44 pt control, leaving a thin glass rim like Telegram.
    private var avatarCircle: some View {
        avatar()
            .frame(width: Self.avatarDiameter, height: Self.avatarDiameter)
            .clipShape(Circle())
            .frame(width: 44, height: 44)
            .contentShape(Circle())
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
            if backBadgeCount > 0 {
                badgedBackControl(action: onBack)
            } else {
                headerControl(
                    action: onBack, systemImage: "chevron.backward", accessibilityLabel: "Back")
            }
        } else if let onClose {
            headerControl(
                action: onClose, systemImage: "xmark", accessibilityLabel: "Close conversation")
        }
    }

    /// Back chevron and unread badge in one glass capsule.
    private func badgedBackControl(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 20, weight: .semibold))
                UnreadBackBadge(count: backBadgeCount)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: true))
        .accessibilityLabel(Text("Back"))
        .accessibilityValue(Text(UnreadBackBadge.accessibilityValue(backBadgeCount)))
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

/// Unread count beside a back chevron, like Messages and Telegram: a black pill with
/// white digits in light mode, white with black digits in dark mode. Explicit colors
/// keep the pill solid instead of picking up the glass's vibrancy.
struct UnreadBackBadge: View {
    let count: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(colorScheme == .dark ? Color.white : Color.black, in: Capsule())
            .accessibilityHidden(true)
    }

    static func accessibilityValue(_ count: Int) -> String {
        AppLanguage.localized("\(count) unread messages")
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
///
/// On iOS the content also extends under the status bar (like Telegram and Messages),
/// and the header inset is measured from the screen top so the first rows still clear
/// the header. macOS keeps the content below the window's title-bar safe area.
struct ChatHeaderOverlay<Header: View>: ViewModifier {
    var isVisible = true
    @ViewBuilder let header: () -> Header
    /// Header frame and the content's top, in window coordinates. The content extends
    /// under the status bar on iOS, so the inset must be measured from its own top, not
    /// from a coordinate space anchored at the safe-area edge.
    @State private var headerFrame = CGRect.zero
    @State private var contentTop: CGFloat = 0

    private static var space: String { "chat-header-overlay" }

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .environment(
                    \.chatHeaderInset,
                    isVisible ? max(0, headerFrame.maxY - contentTop) + 12 : 0
                )
                .ignoresSafeArea(.container, edges: .top)
                .background {
                    GeometryReader { geometry in
                        let top = geometry.frame(in: .global).minY
                        Color.clear
                            .onAppear { contentTop = top }
                            .onChange(of: top) { _, top in contentTop = top }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                }
                .overlay(alignment: .top) {
                    if isVisible {
                        // The timeline draws the backdrop below this header and the
                        // pinned bar, sized to the full `chatHeaderInset`.
                        header()
                            .frame(maxWidth: .infinity)
                            .background { measuredHeader(in: .global) }
                    }
                }
        #else
            GeometryReader { geometry in
                content
                    .environment(\.chatHeaderInset, isVisible ? headerFrame.height + 12 : 0)
                    .overlay(alignment: .top) {
                        if isVisible {
                            header()
                                .frame(maxWidth: .infinity)
                                .background { measuredHeader(in: .named(Self.space)) }
                                .background(alignment: .top) {
                                    ChatHeaderBackdrop(edge: .top, strength: .light)
                                        .frame(
                                            height: headerFrame.height
                                                + geometry.safeAreaInsets.top + 32
                                        )
                                        .offset(y: -geometry.safeAreaInsets.top)
                                }
                        }
                    }
                    .coordinateSpace(.named(Self.space))
            }
        #endif
    }

    private func measuredHeader(in space: CoordinateSpace) -> some View {
        GeometryReader { headerGeometry in
            let frame = headerGeometry.frame(in: space)
            Color.clear
                .onAppear { headerFrame = frame }
                .onChange(of: frame) { _, frame in headerFrame = frame }
        }
    }
}

/// Backdrop behind floating chat chrome whose blur strengthens toward the screen edge.
///
/// SwiftUI has no variable-radius blur, and a single material faded by an opacity
/// mask shows where blurred content meets sharp content. Staggered material layers
/// make the softening ramp up instead of ending at a line.
///
/// - `strong` (iPhone, like Telegram): constant blur from the screen edge, then a
///   fixed-height transition band at the far end; slightly translucent overall.
/// - `light` (macOS, like Telegram for Mac): faint layers fading over the full height.
struct ChatHeaderBackdrop: View {
    enum Strength {
        case light, strong

        /// Fraction of the transition each staggered layer takes to fade out.
        var reaches: [Double] {
            switch self {
            case .light: [1, 0.55]
            case .strong: [1, 0.7, 0.4]
            }
        }

        var layerOpacity: Double {
            switch self {
            case .light: 0.4
            case .strong: 0.4
            }
        }

        /// Points over which the blur fades; `nil` fades over the full height.
        var transitionHeight: CGFloat? {
            switch self {
            case .light: nil
            case .strong: 70
            }
        }
    }

    let edge: VerticalEdge
    let strength: Strength

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            let transition = min(strength.transitionHeight ?? height, height)
            let solid = (height - transition) / height
            ZStack {
                ForEach(strength.reaches, id: \.self) { reach in
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(strength.layerOpacity)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: solid),
                                    .init(
                                        color: .clear,
                                        location: solid + (1 - solid) * reach),
                                ],
                                startPoint: edge == .top ? .top : .bottom,
                                endPoint: edge == .top ? .bottom : .top)
                        }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
