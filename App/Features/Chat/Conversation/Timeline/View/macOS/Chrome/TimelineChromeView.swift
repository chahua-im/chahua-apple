#if os(macOS)
import AppKit
import SwiftUI

/// Retained native state controls sit above, rather than inset, the native table.
@MainActor
final class TimelineChromeView: NSView {
    private struct Presentation: Equatable {
        let state: ConversationTimelineState
        let hasRows: Bool
        let showsJumpToLatest: Bool
        let headerInset: CGFloat
        let composerInset: CGFloat
    }

    private enum Operation: Hashable { case initial, reconcile, jump }
    private weak var model: ConversationTimelineModel?
    private var presentation: Presentation?
    private var tasks: [Operation: Task<Void, Never>] = [:]
    private let initialLoading = TimelineLoadingPanel(label: String(localized: "Loading messages"))
    private let initialFailure = TimelineInitialFailurePanel()
    private let initialBanner = TimelineBannerView(cornerRadius: 0)
    private let olderEdge = TimelineEdgeView(title: String(localized: "Couldn’t load older messages — Retry"))
    private let newerEdge = TimelineEdgeView(title: String(localized: "Couldn’t load newer messages — Retry"))
    private let repositionProgress = TimelineLoadingPanel(label: nil, material: true)
    private let repositionFailure = TimelineBannerView(cornerRadius: ChahuaTheme.Radius.small)
    private let reconciliationFailure = TimelineBannerView(cornerRadius: ChahuaTheme.Radius.small)
    private let jumpControl = TimelineJumpControl()
    private(set) var showsTable = false
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for child in [initialLoading, initialFailure, initialBanner, olderEdge, newerEdge, repositionProgress, repositionFailure, reconciliationFailure, jumpControl] as [NSView] {
            child.isHidden = true
            addSubview(child)
        }
        initialFailure.onRetry = { [weak self] in self?.perform(.initial) }
        initialBanner.onAction = { [weak self] in self?.perform(.initial) }
        olderEdge.onRetry = { [weak self] in self?.model?.retryOlder() }
        newerEdge.onRetry = { [weak self] in self?.model?.retryNewer() }
        repositionFailure.onAction = { [weak self] in self?.model?.dismissRepositionFailure() }
        reconciliationFailure.onAction = { [weak self] in self?.perform(.reconcile) }
        jumpControl.onAction = { [weak self] in self?.perform(.jump) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(model: ConversationTimelineModel, headerInset: CGFloat, composerInset: CGFloat) {
        if self.model !== model {
            cancelPendingActions()
            self.model = model
            presentation = nil
        }
        let next = Presentation(state: model.state, hasRows: !model.rows.isEmpty, showsJumpToLatest: model.showsJumpToLatest, headerInset: headerInset, composerInset: composerInset)
        guard presentation != next else { return }
        presentation = next
        let state = next.state
        let isRepositioning: Bool
        if case .repositioning = state.content { isRepositioning = true }
        else { isRepositioning = false }
        showsTable = next.hasRows || state.content == .ready || isRepositioning

        initialLoading.setLoading(!showsTable && state.content != .initialLoadFailed)
        initialFailure.isHidden = showsTable || state.content != .initialLoadFailed
        if showsTable && (state.content == .idle || state.content == .loadingInitial) {
            initialBanner.configure(text: String(localized: "Loading messages"), action: nil, loading: true)
        } else if showsTable && state.content == .initialLoadFailed {
            initialBanner.configure(text: String(localized: "Couldn’t load messages."), action: String(localized: "Try again"), loading: false)
        } else {
            initialBanner.hide()
        }
        olderEdge.update(showsTable ? state.older : .idle)
        newerEdge.update(showsTable ? state.newer : .idle)
        repositionProgress.setLoading(showsTable && isRepositioning)
        if showsTable, let failure = state.repositionFailure {
            repositionFailure.configure(
                text: failure == .liveEdge ? String(localized: "Couldn’t load messages.") : String(localized: "That message isn’t available."),
                action: String(localized: "Dismiss"), loading: false
            )
        } else {
            repositionFailure.hide()
        }
        if showsTable && state.reconciliationFailed {
            reconciliationFailure.configure(text: String(localized: "Couldn’t refresh messages."), action: String(localized: "Retry"), loading: false)
        } else {
            reconciliationFailure.hide()
        }
        jumpControl.isHidden = !next.showsJumpToLatest
        jumpControl.setCount(model.jumpUnreadCount)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let presentation else { return }
        let width = bounds.width
        let height = bounds.height
        initialLoading.frame = bounds
        initialFailure.frame = bounds
        var top = max(0, presentation.headerInset)
        if !initialBanner.isHidden {
            initialBanner.frame = NSRect(x: 0, y: top, width: width, height: 36)
            top += 36
        }
        olderEdge.frame = NSRect(x: 0, y: top, width: width, height: 48)
        newerEdge.frame = NSRect(x: 0, y: max(0, height - presentation.composerInset - 48), width: width, height: 48)
        // Failures remain non-blocking overlays; they never change row geometry.
        // Keep simultaneous failures individually reachable rather than overlapping.
        var failureTop = max(0, presentation.headerInset) + ChahuaTheme.Spacing.large
        for banner in [repositionFailure, reconciliationFailure] where !banner.isHidden {
            banner.frame = NSRect(x: 16, y: failureTop, width: max(0, width - 32), height: 36)
            failureTop += 44
        }
        repositionProgress.frame = NSRect(x: max(0, (width - 52) / 2), y: max(0, (height - 52) / 2), width: 52, height: 52)
        jumpControl.frame = NSRect(
            x: max(0, width - ChahuaTheme.Spacing.large - 44),
            y: max(0, height - presentation.composerInset - ChahuaTheme.Spacing.large - 44),
            width: 44, height: 44
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let hit = super.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let current = candidate, current !== self {
            if current is NSButton { return hit }
            candidate = current.superview
        }
        // Labels, materials and progress never take selection/scroll hits away
        // from the table, including in non-blocking failure banners.
        return nil
    }

    private func perform(_ operation: Operation) {
        guard tasks[operation] == nil, let model else { return }
        tasks[operation] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            switch operation {
            case .initial: await model.retryInitial()
            case .reconcile: await model.reconcileAfterReconnect()
            case .jump: await model.jumpTowardLatest()
            }
            self?.tasks[operation] = nil
        }
    }

    func cancelPendingActions() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }
}

@MainActor
private final class TimelineChromeButton: NSButton {
    var onAction: (() -> Void)?

    init(title: String, symbol: String? = nil) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryPushIn)
        font = .preferredFont(forTextStyle: .caption1)
        contentTintColor = NSColor(ChahuaTheme.accent)
        target = self
        action = #selector(activate)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            imagePosition = .imageOnly
        }
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { if isEnabled { onAction?() } }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    var titleWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width) + 12
    }
}

@MainActor
private func timelineChromeLabel(_ text: String = "", style: NSFont.TextStyle = .caption1) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .preferredFont(forTextStyle: style)
    label.textColor = .labelColor
    label.isSelectable = false
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
}

@MainActor
private func timelineChromeMaterial(cornerRadius: CGFloat) -> NSVisualEffectView {
    let material = NSVisualEffectView()
    material.material = .contentBackground
    material.blendingMode = .withinWindow
    material.state = .followsWindowActiveState
    material.wantsLayer = true
    material.layer?.cornerRadius = cornerRadius
    material.layer?.masksToBounds = true
    return material
}

@MainActor
private final class TimelineLoadingPanel: NSView {
    private let progress = NSProgressIndicator()
    private let label: NSTextField?
    private let material: NSVisualEffectView?
    override var isFlipped: Bool { true }

    init(label text: String?, material: Bool = false) {
        label = text.map { timelineChromeLabel($0, style: .body) }
        self.material = material ? timelineChromeMaterial(cornerRadius: ChahuaTheme.Radius.medium) : nil
        super.init(frame: .zero)
        if let background = self.material { addSubview(background) }
        progress.style = .spinning
        progress.controlSize = .regular
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel(text ?? String(localized: "Loading messages"))
        addSubview(progress)
        if let label {
            label.alignment = .center
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLoading(_ loading: Bool) {
        isHidden = !loading
        if loading { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
    }

    override func layout() {
        super.layout()
        material?.frame = bounds
        let spinnerSize: CGFloat = 20
        let labelHeight: CGFloat = label == nil ? 0 : 20
        let contentHeight = spinnerSize + (label == nil ? 0 : 8 + labelHeight)
        let top = max(0, (bounds.height - contentHeight) / 2)
        progress.frame = NSRect(x: max(0, (bounds.width - spinnerSize) / 2), y: top, width: spinnerSize, height: spinnerSize)
        label?.frame = NSRect(x: 16, y: top + spinnerSize + 8, width: max(0, bounds.width - 32), height: labelHeight)
    }
}

@MainActor
private final class TimelineInitialFailurePanel: NSView {
    var onRetry: (() -> Void)?
    private let image = NSImageView()
    private let title = timelineChromeLabel(String(localized: "Couldn’t load messages"), style: .headline)
    private let detail = timelineChromeLabel(String(localized: "Check your connection and try again."), style: .body)
    private let retry = TimelineChromeButton(title: String(localized: "Try again"))
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        image.contentTintColor = .labelColor
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityElement(false)
        title.alignment = .center
        detail.alignment = .center
        detail.textColor = NSColor(ChahuaTheme.secondaryText)
        retry.font = .preferredFont(forTextStyle: .body)
        retry.onAction = { [weak self] in self?.onRetry?() }
        for child in [image, title, detail, retry] as [NSView] { addSubview(child) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let top = max(0, (bounds.height - 130) / 2)
        let width = max(0, bounds.width - 32)
        image.frame = NSRect(x: max(0, (bounds.width - 36) / 2), y: top, width: 36, height: 36)
        title.frame = NSRect(x: 16, y: top + 44, width: width, height: 20)
        detail.frame = NSRect(x: 16, y: top + 72, width: width, height: 20)
        let buttonWidth = min(width, retry.titleWidth)
        retry.frame = NSRect(x: (bounds.width - buttonWidth) / 2, y: top + 100, width: buttonWidth, height: 24)
    }
}

@MainActor
private final class TimelineBannerView: NSView {
    var onAction: (() -> Void)?
    private let background: NSVisualEffectView
    private let label = timelineChromeLabel()
    private let button = TimelineChromeButton(title: "")
    private let progress = NSProgressIndicator()
    private var isLoading = false
    override var isFlipped: Bool { true }

    init(cornerRadius: CGFloat) {
        background = timelineChromeMaterial(cornerRadius: cornerRadius)
        super.init(frame: .zero)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        addSubview(background)
        addSubview(label)
        addSubview(button)
        addSubview(progress)
        button.onAction = { [weak self] in self?.onAction?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, action: String?, loading: Bool) {
        isHidden = false
        label.stringValue = text
        label.alignment = loading ? .center : .left
        isLoading = loading
        button.isHidden = action == nil
        button.title = action ?? ""
        button.setAccessibilityLabel(action)
        progress.isHidden = !loading
        progress.setAccessibilityLabel(loading ? text : nil)
        if loading { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        needsLayout = true
    }

    func hide() {
        isHidden = true
        progress.stopAnimation(nil)
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        if isLoading {
            let labelWidth = min(max(0, bounds.width - 48), ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 12)]).width) + 4)
            let left = max(8, (bounds.width - labelWidth - 24) / 2)
            progress.frame = NSRect(x: left, y: (bounds.height - 16) / 2, width: 16, height: 16)
            label.frame = NSRect(x: left + 24, y: (bounds.height - 18) / 2, width: labelWidth, height: 18)
        } else {
            let buttonWidth = min(max(0, bounds.width - 16), button.titleWidth)
            button.frame = NSRect(x: max(8, bounds.width - 8 - buttonWidth), y: (bounds.height - 22) / 2, width: buttonWidth, height: 22)
            label.frame = NSRect(x: 8, y: (bounds.height - 18) / 2, width: max(0, button.frame.minX - 16), height: 18)
        }
    }
}

@MainActor
private final class TimelineEdgeView: NSView {
    var onRetry: (() -> Void)?
    private let progress = NSProgressIndicator()
    private let retry: TimelineChromeButton
    override var isFlipped: Bool { true }

    init(title: String) {
        retry = TimelineChromeButton(title: title)
        super.init(frame: .zero)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel(String(localized: "Loading messages"))
        retry.font = .preferredFont(forTextStyle: .body)
        retry.onAction = { [weak self] in self?.onRetry?() }
        addSubview(progress)
        addSubview(retry)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ edge: ConversationTimelineState.Edge) {
        isHidden = edge == .idle
        progress.isHidden = edge != .loading
        retry.isHidden = edge != .failed
        if edge == .loading { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
    }

    override func layout() {
        super.layout()
        progress.frame = NSRect(x: max(0, (bounds.width - 16) / 2), y: 16, width: 16, height: 16)
        let width = min(max(0, bounds.width - 32), retry.titleWidth)
        retry.frame = NSRect(x: (bounds.width - width) / 2, y: 12, width: width, height: 24)
    }
}

@MainActor
private final class TimelineJumpControl: NSView {
    var onAction: (() -> Void)?
    private let background = timelineChromeMaterial(cornerRadius: 22)
    private let button = TimelineChromeButton(title: String(localized: "Jump to latest messages"), symbol: "chevron.down")
    private let badge = timelineChromeLabel(style: .caption2)
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.contentTintColor = .labelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        button.onAction = { [weak self] in self?.onAction?() }
        let caption = NSFont.preferredFont(forTextStyle: .caption2)
        badge.font = NSFontManager.shared.convert(caption, toHaveTrait: .boldFontMask)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.masksToBounds = true
        badge.isHidden = true
        badge.setAccessibilityElement(false)
        addSubview(background)
        addSubview(button)
        addSubview(badge)
        updateBadgeColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCount(_ count: Int64) {
        let title = String(localized: "Jump to latest messages")
        badge.stringValue = String(max(0, count))
        badge.isHidden = count <= 0
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(count > 0 ? String(localized: "\(count) unread messages") : nil)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        button.frame = bounds
        let font = badge.font ?? NSFont.systemFont(ofSize: 11)
        let textSize = (badge.stringValue as NSString).size(withAttributes: [.font: font])
        let height = ceil(textSize.height) + 10
        let width = max(height, ceil(textSize.width) + 10)
        badge.frame = NSRect(x: bounds.maxX - width + 8, y: -8, width: width, height: height)
        badge.layer?.cornerRadius = height / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? button : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBadgeColor()
    }

    private func updateBadgeColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.layer?.backgroundColor = NSColor(ChahuaTheme.accent).cgColor
        }
    }
}
#endif
