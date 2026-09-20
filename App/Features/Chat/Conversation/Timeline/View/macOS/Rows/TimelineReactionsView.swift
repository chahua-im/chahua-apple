#if os(macOS)
import AppKit
import ChahuaAPI
import SwiftUI

@MainActor
final class TimelineReactionsView: NSView {
    private var binding: TimelineRowBinding?
    private var pills: [TimelineReactionButton] = []
    private var visible = false
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func bind(_ binding: TimelineRowBinding) {
        self.binding = binding
        guard case .message(let row) = binding.presentation.row, row.entry.remoteMessage?.isDeleted != true else { clear(); return }
        let reactions = (row.entry.remoteMessage?.reactions ?? []).sorted(by: TimelineRowPresentation.reactionOrder)
        let count = min(reactions.count, binding.layout.reactionFrames.count)
        while pills.count < count {
            let pill = TimelineReactionButton(frame: .zero)
            addSubview(pill); pills.append(pill)
        }
        let pending = binding.actions.pendingReactionMessageIDs.contains(row.entry.remoteMessage?.id ?? "")
        let eligibility = MessageReactionEligibility(canReact: MessageActionPolicy(row: row, context: binding.actions.interactionContext).canReact && binding.actions.toggleReaction != nil,
                                                     isReacting: pending, reactions: reactions)
        for index in pills.indices {
            let pill = pills[index]
            guard index < count else { pill.clear(); pill.isHidden = true; continue }
            let reaction = reactions[index]
            pill.isHidden = false
            pill.configure(reaction, outgoing: row.isOutgoing, pending: pending, enabled: eligibility.canToggle(reaction.emoji),
                           displayScale: binding.presentation.environment.displayScale, mediaContext: binding.mediaContext,
                           contentFrames: index < binding.layout.reactionContentFrames.count ? binding.layout.reactionContentFrames[index] : [])
            pill.onActivate = { [weak self, weak pill] in
                guard let emoji = pill?.emoji else { return }
                self?.activate(emoji)
            }
            pill.setVisible(visible)
        }
        needsLayout = true
    }

    func clear() {
        binding = nil; visible = false
        for pill in pills { pill.clear(); pill.isHidden = true }
    }
    func setVisible(_ visible: Bool) {
        self.visible = visible
        for pill in pills { pill.setVisible(visible && !pill.isHidden) }
    }
    override func layout() {
        super.layout()
        let frames = binding?.layout.reactionFrames ?? []
        for index in pills.indices { pills[index].frame = index < frames.count ? frames[index] : .zero }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { setVisible(false) } }

    private func activate(_ emoji: String) {
        guard let binding, !binding.context.isInteractionPreview, case .message(let row) = binding.presentation.row,
              let message = row.entry.remoteMessage, let action = binding.actions.toggleReaction,
              message.reactions.contains(where: { $0.emoji == emoji }) else { return }
        let eligibility = MessageReactionEligibility(canReact: MessageActionPolicy(row: row, context: binding.actions.interactionContext).canReact,
                                                     isReacting: binding.actions.pendingReactionMessageIDs.contains(message.id), reactions: message.reactions)
        guard eligibility.canToggle(emoji) else { return }
        action(row, emoji)
    }
}

private final class ReactionLabelCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { rect }
    override func titleRect(forBounds rect: NSRect) -> NSRect { rect }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Match the layout engine's glyph measurements without NSTextFieldCell's
        // additional internal padding, which clips narrow reaction counts.
        attributedStringValue.draw(with: cellFrame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
private final class ReactionLabel: NSTextField {
    init() {
        super.init(frame: .zero); cell = ReactionLabelCell(textCell: "")
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        maximumNumberOfLines = 1; lineBreakMode = .byClipping; cell?.wraps = false; cell?.isScrollable = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class TimelineReactionButton: NSButton {
    private(set) var emoji: String?
    var onActivate: (() -> Void)?
    private let emojiLabel = ReactionLabel()
    private let countLabel = ReactionLabel()
    private var avatars: [TimelineAvatarView] = []
    private var avatarCount = 0
    private var outgoing = false
    private var selected = false
    private var visible = false
    private var contentFrames: [CGRect] = []
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""; isBordered = false; setButtonType(.momentaryPushIn)
        target = self; action = #selector(activate)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        emojiLabel.font = .systemFont(ofSize: 18.5)
        addSubview(emojiLabel); addSubview(countLabel)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ reaction: ReactionSummary, outgoing: Bool, pending: Bool, enabled: Bool, displayScale: CGFloat, mediaContext: AppMediaContext?, contentFrames: [CGRect]) {
        self.contentFrames = contentFrames
        emoji = reaction.emoji; emojiLabel.stringValue = reaction.emoji
        self.outgoing = outgoing; selected = reaction.reactedByMe == true
        isEnabled = enabled; alphaValue = pending ? 0.6 : 1
        let reactors = reaction.reactors ?? []
        avatarCount = min(5, reactors.count)
        while avatars.count < avatarCount {
            let avatar = TimelineAvatarView(frame: .zero)
            if let last = avatars.last { addSubview(avatar, positioned: .below, relativeTo: last) }
            else { addSubview(avatar) }
            avatars.append(avatar)
            avatar.setAccessibilityElement(false)
        }
        for index in avatars.indices {
            let avatar = avatars[index]
            guard index < avatarCount else { avatar.clear(); avatar.isHidden = true; continue }
            let reactor = reactors[index]
            avatar.isHidden = false
            avatar.configure(url: reactor.avatarUrl.flatMap(URL.init(string:)), name: reactor.name ?? "User \(reactor.uid)",
                             userID: reactor.uid, diameter: 23, displayScale: displayScale, mediaContext: mediaContext)
            avatar.setAccessibilityElement(false)
            avatar.setVisible(visible)
        }
        if avatarCount > 0, reaction.count > 5 {
            countLabel.stringValue = "+\(reaction.count - 5)"; countLabel.font = .systemFont(ofSize: 11)
        } else if avatarCount == 0, reaction.count > 1 {
            countLabel.stringValue = "\(reaction.count)"; countLabel.font = .systemFont(ofSize: 12)
        } else { countLabel.stringValue = "" }
        countLabel.isHidden = countLabel.stringValue.isEmpty
        setAccessibilityLabel("\(reaction.emoji), \(reaction.count) reactions")
        setAccessibilitySelected(selected)
        updatePaint(); needsLayout = true
    }

    func clear() {
        emoji = nil; emojiLabel.stringValue = ""; countLabel.stringValue = ""; onActivate = nil
        avatarCount = 0; visible = false; isEnabled = false
        contentFrames.removeAll(keepingCapacity: true)
        for avatar in avatars { avatar.clear(); avatar.isHidden = true }
        setAccessibilityLabel(nil); setAccessibilitySelected(false)
    }
    func setVisible(_ visible: Bool) {
        self.visible = visible
        for avatar in avatars { avatar.setVisible(visible && !avatar.isHidden) }
    }
    override func layout() {
        super.layout()
        emojiLabel.frame = contentFrames.first ?? .zero
        countLabel.frame = contentFrames.count > 1 ? contentFrames[1] : .zero
        for index in avatars.indices {
            avatars[index].frame = index < avatarCount && index + 2 < contentFrames.count ? contentFrames[index + 2] : .zero
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updatePaint() }
    private func updatePaint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let foreground = selected ? NSColor.white : NSColor(ChahuaTheme.ChatBubble.incomingForeground(for: dark ? .dark : .light))
            let background: NSColor
            if outgoing && selected { background = NSColor(srgbRed: 38 / 255, green: 107 / 255, blue: 180 / 255, alpha: 1) }
            else if selected { background = NSColor(srgbRed: 64 / 255, green: 135 / 255, blue: 210 / 255, alpha: 1) }
            else if dark { background = NSColor(srgbRed: 30 / 255, green: 32 / 255, blue: 35 / 255, alpha: 1) }
            else { background = NSColor(srgbRed: 215 / 255, green: 216 / 255, blue: 218 / 255, alpha: 1) }
            layer?.backgroundColor = background.cgColor
            emojiLabel.textColor = foreground; countLabel.textColor = foreground.withAlphaComponent(0.7)
            for avatar in avatars { avatar.layer?.borderWidth = 1; avatar.layer?.borderColor = foreground.cgColor; avatar.layer?.cornerRadius = 11.5 }
        }
    }
    @objc private func activate() { if isEnabled, emoji != nil { onActivate?() } }
}
#endif
