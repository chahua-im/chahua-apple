#if os(macOS)
    import AppKit
    import SwiftUI

    /// Native table chrome must retain its controls independently of SwiftUI's
    /// layout/observation cycle, including while the viewport is scrolling.
    @MainActor
    final class TimelineNativeNavigationControls: NSView {
        var onLatest: (() -> Void)?
        var onMention: (() -> Void)?
        var onReaction: (() -> Void)?
        private let reaction = TimelineNavigationButton(symbol: "heart.fill")
        private let mention = TimelineNavigationButton(symbol: "at")
        private let latest = TimelineNavigationButton(symbol: "chevron.down")
        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            clipsToBounds = false
            for button in [reaction, mention, latest] { addSubview(button) }
            reaction.onPress = { [weak self] in self?.onReaction?() }
            mention.onPress = { [weak self] in self?.onMention?() }
            latest.onPress = { [weak self] in self?.onLatest?() }
            isHidden = true
        }
        required init?(coder: NSCoder) { nil }

        func configure(
            showsLatest: Bool, messages: Int64, mentions: Int, reactions: Int,
            busy: Bool, badgeColor: ConversationUnreadBadgeColor
        ) {
            reaction.isHidden = reactions <= 0
            mention.isHidden = mentions <= 0
            latest.isHidden = !showsLatest
            reaction.configure(
                count: Int64(reactions), label: "Jump to next reaction",
                value: AppLanguage.localized("\(reactions) unread reactions"), color: badgeColor)
            mention.configure(
                count: Int64(mentions), label: "Jump to next mention or reply",
                value: AppLanguage.localized("\(mentions) unread mentions and replies"),
                color: badgeColor)
            latest.configure(
                count: messages, label: "Jump to latest messages",
                value: messages > 0 ? AppLanguage.localized("\(messages) unread messages") : "",
                color: badgeColor)
            for button in [reaction, mention, latest] { button.isEnabled = !busy }
            isHidden = reaction.isHidden && mention.isHidden && latest.isHidden
            invalidateIntrinsicContentSize()
            needsLayout = true
        }

        override var fittingSize: NSSize { intrinsicContentSize }
        override var intrinsicContentSize: NSSize {
            let count = [reaction, mention, latest].filter { !$0.isHidden }.count
            let width = max(
                reaction.requiredWidth, max(mention.requiredWidth, latest.requiredWidth))
            return NSSize(
                width: width,
                height: 8 + CGFloat(count) * 32
                    + CGFloat(max(0, count - 1)) * ChahuaTheme.Spacing.medium)
        }

        override func layout() {
            super.layout()
            var y: CGFloat = 8
            for button in [reaction, mention, latest] where !button.isHidden {
                button.frame = NSRect(x: 0, y: y, width: bounds.width, height: 32)
                y += 32 + ChahuaTheme.Spacing.medium
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden else { return nil }
            let point = convert(point, from: superview)
            for button in [reaction, mention, latest] where !button.isHidden {
                if button.frame.union(button.frame.offsetBy(dx: 0, dy: -8)).contains(point) {
                    return button
                }
            }
            return nil
        }
    }

    @MainActor
    private final class TimelineNavigationButton: NSButton {
        var onPress: (() -> Void)?
        private let material: NSView
        private let symbolView = NSImageView()
        private let badgeBackground = NSView()
        private let badge = NSTextField(labelWithString: "")
        private let badgeFont = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .bold)
        private var badgeWidth: CGFloat = 22
        var requiredWidth: CGFloat { 40 }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { isEnabled }
        override var isEnabled: Bool {
            didSet {
                symbolView.alphaValue = isEnabled ? 1 : 0.4
                badgeBackground.alphaValue = isEnabled ? 1 : 0.4
            }
        }

        init(symbol: String) {
            if #available(macOS 26, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = 16
                glass.style = .regular
                if #available(macOS 27, *) { glass.effectIsInteractive = true }
                material = glass
            } else {
                let effect = NSVisualEffectView()
                effect.material = .popover
                effect.blendingMode = .withinWindow
                effect.state = .active
                effect.wantsLayer = true
                effect.layer?.cornerRadius = 16
                effect.layer?.masksToBounds = true
                material = effect
            }
            super.init(frame: .zero)
            clipsToBounds = false
            title = ""
            isBordered = false
            setButtonType(.momentaryPushIn)
            symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(
                        pointSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
                        weight: .semibold))
            imagePosition = .imageOnly
            contentTintColor = .labelColor
            target = self
            action = #selector(activate)
            addSubview(material, positioned: .below, relativeTo: nil)
            symbolView.contentTintColor = .labelColor
            symbolView.imageScaling = .scaleNone
            symbolView.setAccessibilityElement(false)
            addSubview(symbolView)
            badge.font = badgeFont
            badge.textColor = .white
            badge.alignment = .center
            badge.setAccessibilityElement(false)
            badgeBackground.wantsLayer = true
            badgeBackground.isHidden = true
            badgeBackground.setAccessibilityElement(false)
            badgeBackground.addSubview(badge)
            addSubview(badgeBackground)
        }
        required init?(coder: NSCoder) { nil }

        func configure(
            count: Int64, label: String.LocalizationValue, value: String,
            color: ConversationUnreadBadgeColor
        ) {
            badge.stringValue = count > 999 ? "999+" : String(count)
            badgeBackground.isHidden = count <= 0
            badgeWidth = max(
                22,
                ceil((badge.stringValue as NSString).size(withAttributes: [.font: badgeFont]).width)
                    + 10)
            badgeBackground.layer?.backgroundColor = NSColor(color.color).cgColor
            let label = AppLanguage.localized(label)
            setAccessibilityLabel(label)
            setAccessibilityValue(value)
            toolTip = label
            needsLayout = true
        }

        override func layout() {
            super.layout()
            material.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
            symbolView.frame = material.frame
            let height = max(22, badgeFont.pointSize * 2)
            badgeBackground.frame = NSRect(
                x: 40 - badgeWidth, y: -8, width: badgeWidth, height: height)
            badgeBackground.layer?.cornerRadius = height / 2
            // NSTextField aligns text at the top of a tall frame. Center its
            // measured line box inside the badge instead of stretching the label.
            let labelHeight = min(height, ceil(badge.intrinsicContentSize.height))
            badge.frame = NSRect(
                x: 0, y: (height - labelHeight) / 2,
                width: badgeWidth, height: labelHeight)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden else { return nil }
            let local = convert(point, from: superview)
            return bounds.union(badgeBackground.frame).contains(local) ? self : nil
        }
        override func resetCursorRects() {
            super.resetCursorRects()
            if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
        }
        @objc private func activate() { if isEnabled { onPress?() } }
    }
#endif
