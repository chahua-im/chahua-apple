import ChahuaAPI
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Shared geometry for the adaptive chat shell and its macOS window minimum.
enum ChatSplitMetrics {
    static let splitThreshold: CGFloat = 768
    #if os(macOS)
        static let initialSidebarWidth: CGFloat = 300
        static let minimumSidebarWidth: CGFloat = 300
        static let maximumSidebarWidth: CGFloat = 340
        static let dividerWidth: CGFloat = 0
        static let outerInset: CGFloat = 8
        static let sidebarOuterInset: CGFloat = 0
    #else
        static let initialSidebarWidth: CGFloat = 320
        static let minimumSidebarWidth: CGFloat = 300
        static let maximumSidebarWidth: CGFloat = 340
        static let dividerWidth: CGFloat = 12
        static let outerInset: CGFloat = 12
        static let sidebarOuterInset: CGFloat = 12
    #endif
    static let minimumDetailWidth: CGFloat = 440
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
    @State private var isSplit = false
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
        ChatSplitPaneLayout(
            preferredSidebarWidth: preferredSidebarWidth, hasSelection: hasSelection
        ) {
            pane(
                sidebar(isSplit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(macOS)
                        .modifier(MacChatSidebarSurface(isSplit: isSplit))
                    #else
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: isSplit ? 20 : 0))
                    #endif
                    .padding(.leading, isSplit ? ChatSplitMetrics.sidebarOuterInset : 0)
                    .padding(.vertical, isSplit ? ChatSplitMetrics.sidebarOuterInset : 0),
                isVisible: isSplit || !hasSelection
            )
            pane(detail(isSplit), isVisible: isSplit || hasSelection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.isWideChatLayout, isSplit)
        .overlay {
            // Only the divider needs the exact width for dragging and accessibility.
            // A window resize must not rebuild either pane's content at every pixel.
            GeometryReader { geometry in
                let availableWidth = geometry.size.width
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                        .frame(width: effectiveSidebarWidth(for: availableWidth))
                    splitDivider(isSplit: isSplit, availableWidth: availableWidth)
                        .frame(width: ChatSplitMetrics.dividerWidth)
                    Spacer(minLength: 0)
                }
            }
            .opacity(isSplit ? 1 : 0)
            .allowsHitTesting(isSplit)
            .accessibilityHidden(!isSplit)
        }
        .onGeometryChange(for: Bool.self) {
            $0.size.width >= ChatSplitMetrics.splitThreshold
        } action: { split in
            isSplit = split
            if !split { dragStartWidth = nil }
        }
        #if os(macOS)
            .environment(\.isChatSplitResizing, isSplit && isResizing)
            .onChange(of: isResizing) { _, resizing in
                // Gesture state also resets when SwiftUI cancels the drag.
                if !resizing { dragStartWidth = nil }
            }
        #endif
        #if os(macOS)
            .ignoresSafeArea(.container, edges: .top)
        #endif
        .background(ChahuaTheme.conversationBackground(for: colorScheme))
    }

    private func pane<Content: View>(_ content: Content, isVisible: Bool) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }

    private func splitDivider(isSplit: Bool, availableWidth: CGFloat) -> some View {
        Color.clear
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
        ChatSplitPaneLayout.sidebarWidth(width, availableWidth: availableWidth)
    }
}

/// Width changes belong to layout, not to the view values that build both panes.
/// Keep both children mounted across the compact breakpoint to retain navigation.
private struct ChatSplitPaneLayout: Layout {
    var preferredSidebarWidth: CGFloat
    var hasSelection: Bool

    static func sidebarWidth(_ preferredWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let maximumAllowed = min(
            ChatSplitMetrics.maximumSidebarWidth,
            availableWidth - ChatSplitMetrics.minimumDetailWidth - ChatSplitMetrics.dividerWidth)
        return max(
            0, min(max(preferredWidth, ChatSplitMetrics.minimumSidebarWidth), maximumAllowed))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 10, height: 10))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let split = bounds.width >= ChatSplitMetrics.splitThreshold
        let sidebar =
            split
            ? Self.sidebarWidth(preferredSidebarWidth, availableWidth: bounds.width)
            : (hasSelection ? 0 : bounds.width)
        let divider = split ? ChatSplitMetrics.dividerWidth : 0
        let detail = max(0, bounds.width - sidebar - divider)
        // SwiftUI mirrors the layout's logical coordinates for right-to-left content.
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading, proposal: ProposedViewSize(width: sidebar, height: bounds.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + sidebar + divider, y: bounds.minY),
            anchor: .topLeading, proposal: ProposedViewSize(width: detail, height: bounds.height))
    }
}

/// In-content chrome shared by the adaptive conversation and its diagnostic surface.
struct ChatFloatingHeader<Avatar: View>: View {
    let title: String
    var subtitle: String?
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenInfo: (() -> Void)?
    var onSearch: (() -> Void)?
    var isSearchPresented = false
    var notificationChat: ChatListItem?
    var notificationDefaults: NotificationSettingsResponse?
    var onUpdateNotifications: ((ChatListItem, UpdateNotificationSettingRequest?) -> Void)?
    var isUpdatingMute = false
    var isInspectorPresented = false
    var onForward: (() -> Void)?
    /// The trailing slot holds its own control (e.g. the thread subscription menu)
    /// rather than a decorative avatar.
    var trailingIsControl = false
    /// Server-owned Main badge outside the current parent chat; 0 hides it.
    var backBadgeCount = 0
    var backBadgeShowsMessageCount = false
    /// Thread identity shares one glass capsule with its avatar; navigation stays separate.
    var leadingAvatar: ThreadHeaderAvatar? = nil
    @ScaledMetric(relativeTo: .body) private var avatarScale: CGFloat = 1
    @Environment(\.isWideChatLayout) private var isWideChatLayout
    @ViewBuilder var avatar: () -> Avatar

    private var usesDesktopChrome: Bool {
        // macOS uses compact pointer targets in one action capsule. Keep the larger
        // touch targets and separate circular controls on iPhone/iPad; a shared
        // compact frame would reduce their touch area. SwiftUI supplies both layouts.
        #if os(macOS)
            true
        #else
            false
        #endif
    }

    private var isMuted: Bool {
        notificationChat?.notificationMuted(defaults: notificationDefaults) == true
    }

    var body: some View {
        if isWideChatLayout {
            HStack(spacing: usesDesktopChrome ? 10 : 8) {
                navigationControl
                identity
                    .frame(minWidth: 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if onSearch != nil || (notificationChat != nil && onUpdateNotifications != nil)
                    || onOpenInfo != nil || onForward != nil || trailingIsControl
                {
                    wideControls
                        .fixedSize(horizontal: usesDesktopChrome, vertical: false)
                        .layoutPriority(usesDesktopChrome ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity)
            .background { searchShortcut }
        } else {
            ZStack {
                // Symmetric edge slots keep the whole identity capsule centered on phones.
                identity
                    .padding(
                        .horizontal,
                        max(
                            backBadgeCount > 0 ? 92 : 52,
                            onForward != nil
                                ? 104
                                : trailingIsControl ? 52 : Self.avatarDiameter * avatarScale + 8))
                HStack {
                    navigationControl
                    Spacer(minLength: 0)
                    trailingControls
                }
            }
            .background { searchShortcut }
        }
    }

    private var wideControls: some View {
        HStack(spacing: usesDesktopChrome ? 2 : 0) {
            if let onSearch {
                wideControl("Search messages", systemImage: "magnifyingglass", action: onSearch)
                    .foregroundStyle(isSearchPresented ? Color.accentColor : Color.primary)
            }
            if let notificationChat, let onUpdateNotifications {
                Menu {
                    ChatNotificationMenuContent(
                        chat: notificationChat, defaults: notificationDefaults
                    ) { request in
                        onUpdateNotifications(notificationChat, request)
                    }
                } label: {
                    Image(systemName: isMuted ? "bell.slash" : "bell")
                        .font(.system(size: 18))
                        .frame(
                            width: usesDesktopChrome ? 32 : 40,
                            height: usesDesktopChrome ? 32 : 44
                        )
                        .contentShape(Rectangle())
                }
                #if os(macOS)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                #endif
                .buttonStyle(.plain)
                .accessibilityLabel("Notification settings")
                .accessibilityIdentifier("chat-notification-settings")
                .disabled(isUpdatingMute)
            }
            if let onOpenInfo {
                wideControl(
                    "Chat information", systemImage: "sidebar.right", action: onOpenInfo
                )
                .foregroundStyle(isInspectorPresented ? Color.accentColor : Color.primary)
                .accessibilityValue(isInspectorPresented ? "Open" : "Closed")
                .accessibilityIdentifier("chat-inspector-toggle")
            }
            if usesDesktopChrome {
                if let onForward {
                    wideControl(
                        "Forward Thread", systemImage: "arrowshape.turn.up.right", action: onForward
                    )
                }
                if trailingIsControl {
                    // The slot is already a button; do not add glass or an info button
                    // around it. Normal-chat avatars remain in the identity capsule.
                    avatar()
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            } else if onForward != nil || trailingIsControl {
                trailingControls
            }
        }
        .padding(.horizontal, usesDesktopChrome ? 8 : 4)
        .padding(.vertical, usesDesktopChrome ? 8 : 4)
        .modifier(ChatGlassSurface(shape: Capsule(style: .circular), isInteractive: true))
    }

    private func wideControl(
        _ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .frame(width: usesDesktopChrome ? 32 : 40, height: usesDesktopChrome ? 32 : 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
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
        HStack(spacing: usesDesktopChrome ? 10 : 8) {
            if let leadingAvatar {
                // Let the avatar keep its Dynamic Type size, including its author badge.
                leadingAvatar.fixedSize()
            } else if isWideChatLayout && !trailingIsControl {
                avatar()
                    .frame(width: usesDesktopChrome ? 34 : 36, height: usesDesktopChrome ? 34 : 36)
            }
            VStack(alignment: isWideChatLayout ? .leading : .center, spacing: 0) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(usesDesktopChrome ? .system(size: 14, weight: .semibold) : .headline)
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
                        .font(usesDesktopChrome ? .system(size: 11) : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(
            .leading, usesDesktopChrome ? 7 : (isWideChatLayout || leadingAvatar != nil ? 8 : 18)
        )
        .padding(.trailing, usesDesktopChrome ? 16 : (leadingAvatar == nil ? 18 : 12))
        .padding(.vertical, 4)
        .frame(minHeight: usesDesktopChrome ? 48 : 44)
        .frame(maxWidth: isWideChatLayout ? .infinity : nil, alignment: .leading)
        .contentShape(Capsule(style: .circular))
        .modifier(
            ChatGlassSurface(shape: Capsule(style: .circular), isInteractive: onOpenInfo != nil))
    }

    /// Built like `headerControl`: the glass wraps the button rather than sitting inside
    /// its label, and is not clipped, so the interactive glass can bulge and highlight
    /// on press instead of the touch landing on a flat, clipped avatar image.
    private var trailingControls: some View {
        HStack(spacing: 8) {
            if let onForward {
                Button(action: onForward) {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Forward Thread")
                .modifier(ChatGlassSurface(shape: Circle(), isInteractive: true))
            }
            trailingAvatar
        }
    }

    private var trailingAvatar: some View {
        let isInteractive = onOpenInfo != nil || trailingIsControl
        return Group {
            if let onOpenInfo {
                Button(action: onOpenInfo) { avatarCircle }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Open chat information"))
                    .accessibilityValue(subtitle ?? "")
                    .accessibilityIdentifier("group-info-avatar-button")
            } else {
                avatarCircle
                    .accessibilityHidden(!isInteractive)
            }
        }
        // The avatar's online dot overlaps its image edge; preserve it while the
        // surrounding glass and hit region remain circular.
        .modifier(
            ChatGlassSurface(shape: Circle(), isInteractive: isInteractive, clipsContent: false))
    }

    /// Avatars own their scaled bounds and presence ring; controls instead fill a
    /// bounded hit target. A filling control must never receive the screen proposal.
    @ViewBuilder
    private var avatarCircle: some View {
        if trailingIsControl {
            avatar()
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        } else {
            avatar()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
    }

    /// Base avatar diameter; trailing controls stay 44 pt while avatars scale independently.
    static var avatarDiameter: CGFloat {
        #if os(macOS)
            34
        #else
            38
        #endif
    }

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
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.plain)
        .modifier(ChatGlassSurface(shape: Capsule(style: .circular), isInteractive: true))
        .accessibilityLabel(Text("Back"))
        .accessibilityValue(
            Text(
                UnreadBackBadge.accessibilityValue(
                    backBadgeCount, showUnreadMessageCount: backBadgeShowsMessageCount)))
    }

    @ViewBuilder
    private func headerControl(
        action: @escaping () -> Void, systemImage: String, accessibilityLabel: String
    ) -> some View {
        let label = Image(systemName: systemImage)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 44, height: 44)
            // Plain buttons must hit-test the circular control, not just the symbol.
            .contentShape(Circle())
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
                    .modifier(ChatGlassSurface(shape: Circle(), isInteractive: true))
                    .accessibilityLabel(accessibilityLabel)
            }
        #else
            Button(action: action) { label }
                .buttonStyle(.plain)
                .modifier(ChatGlassSurface(shape: Circle(), isInteractive: true))
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

    private var renderedLabel: String { count > 99 ? "99+" : "\(count)" }

    var body: some View {
        RoundChipLayout(isCircular: renderedLabel.count == 1) {
            Text(renderedLabel)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .padding(.horizontal, 6)
                .frame(minWidth: 22, minHeight: 22)
        }
        .background(
            colorScheme == .dark ? Color.white : Color.black, in: Capsule(style: .circular)
        )
        .accessibilityHidden(true)
    }

    static func accessibilityValue(_ count: Int, showUnreadMessageCount: Bool = false) -> String {
        showUnreadMessageCount
            ? AppLanguage.localized("\(count) unread messages")
            : AppLanguage.localized("\(count) unread chats")
    }
}

/// Each caller names its geometry; clipping and hit testing share the glass outline.
struct ChatGlassSurface<Surface: InsettableShape>: ViewModifier {
    let shape: Surface
    var isInteractive = false
    var clipsContent = true

    @ViewBuilder
    func body(content: Content) -> some View {
        // Clip the content, not the glass effect, so interactive glass can still
        // bulge on press without exposing rectangular content or hit regions.
        let surface = clippedContent(content).contentShape(shape)
        if #available(macOS 26, iOS 26, *) {
            surface.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        } else {
            surface
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(0.08)) }
        }
    }

    @ViewBuilder
    private func clippedContent(_ content: Content) -> some View {
        if clipsContent {
            content.clipShape(shape)
        } else {
            content
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

/// Floating title chrome publishes scrollable clearance without shrinking the viewport.
struct ChatHeaderOverlay<Header: View>: ViewModifier {
    var isVisible = true
    @ViewBuilder let header: () -> Header
    #if os(iOS)
        /// The content extends under the status bar, so measure from its own window
        /// origin rather than a coordinate space anchored at the safe-area edge.
        @State private var headerFrame = CGRect.zero
        @State private var contentTop: CGFloat = 0
    #else
        @State private var headerHeight: CGFloat = 0
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                // Loading and failure placeholders have intrinsic height; anchor
                // floating chrome to the viewport, not their centered content.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // AppKit's viewport must fill the original container so rows can pass
            // beneath the title. Measure only this overlay's local height: feeding
            // window-space frames back into layout can grow the inset on resize.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.chatHeaderInset, isVisible ? headerHeight + 12 + 8 : 0)
                .overlay(alignment: .top) {
                    if isVisible {
                        header()
                            .frame(maxWidth: .infinity)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear
                                        .onAppear { headerHeight = geometry.size.height }
                                        .onChange(of: geometry.size.height) { _, height in
                                            ScrollPerformanceTrace.event("Header.Height")
                                            headerHeight = height
                                        }
                                }
                            }
                            .padding(.top, 12)
                    }
                }
        #endif
    }

    #if os(iOS)
        private func measuredHeader(in space: CoordinateSpace) -> some View {
            GeometryReader { headerGeometry in
                let frame = headerGeometry.frame(in: space)
                Color.clear
                    .onAppear { headerFrame = frame }
                    .onChange(of: frame) { _, frame in headerFrame = frame }
            }
        }
    #endif
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
