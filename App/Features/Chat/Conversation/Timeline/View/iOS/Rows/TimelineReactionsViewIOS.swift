#if os(iOS)
import ChahuaAPI
import SwiftUI
import UIKit

/// Measured UIKit pills avoid a separate SwiftUI layout/hosting tree in every
/// row and let the row's single gesture coordinator arbitrate taps versus swipes.
@MainActor
final class TimelineReactionsView: UIView {
    private var binding: TimelineRowBinding?
    private var pills: [TimelineReactionButton] = []
    private var visible = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    func bind(_ binding: TimelineRowBinding) {
        self.binding = binding
        guard case .message(let row) = binding.presentation.row,
              row.entry.remoteMessage?.isDeleted != true else { clear(); return }
        let reactions = (row.entry.remoteMessage?.reactions ?? []).sorted(by: TimelineRowPresentation.reactionOrder)
        let count = min(reactions.count, binding.layout.reactionFrames.count)
        while pills.count < count {
            let pill = TimelineReactionButton(frame: .zero)
            addSubview(pill)
            pills.append(pill)
        }
        let pending = binding.actions.pendingReactionMessageIDs.contains(row.entry.remoteMessage?.id ?? "")
        let eligibility = MessageReactionEligibility(
            canReact: !binding.context.isInteractionPreview
                && MessageActionPolicy(row: row, context: binding.actions.interactionContext).canReact
                && binding.actions.toggleReaction != nil,
            isReacting: pending, reactions: reactions
        )
        for index in pills.indices {
            let pill = pills[index]
            guard index < count else { pill.clear(); pill.isHidden = true; continue }
            let reaction = reactions[index]
            pill.isHidden = false
            pill.onActivate = { [weak self, weak pill] in
                guard let emoji = pill?.emoji else { return }
                self?.activate(emoji)
            }
            pill.configure(reaction, outgoing: row.isOutgoing, pending: pending, enabled: eligibility.canToggle(reaction.emoji),
                           displayScale: binding.presentation.environment.displayScale, mediaContext: binding.mediaContext,
                           contentFrames: index < binding.layout.reactionContentFrames.count ? binding.layout.reactionContentFrames[index] : [])
            pill.setVisible(visible)
        }
        setNeedsLayout()
    }

    func clear() {
        binding = nil
        visible = false
        for pill in pills { pill.clear(); pill.isHidden = true }
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        for pill in pills { pill.setVisible(visible && !pill.isHidden) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = binding?.layout.reactionFrames ?? []
        for index in pills.indices { pills[index].frame = index < frames.count ? frames[index] : .zero }
    }

    private func activate(_ emoji: String) {
        guard let binding, !binding.context.isInteractionPreview, case .message(let row) = binding.presentation.row,
              let message = row.entry.remoteMessage, let action = binding.actions.toggleReaction,
              message.reactions.contains(where: { $0.emoji == emoji }) else { return }
        let eligibility = MessageReactionEligibility(
            canReact: MessageActionPolicy(row: row, context: binding.actions.interactionContext).canReact,
            isReacting: binding.actions.pendingReactionMessageIDs.contains(message.id), reactions: message.reactions
        )
        guard eligibility.canToggle(emoji) else { return }
        action(row, emoji)
    }
}

@MainActor
private final class TimelineReactionButton: UIControl {
    private(set) var emoji: String?
    var onActivate: (() -> Void)?
    private let emojiLabel = UILabel(frame: .zero)
    private let countLabel = UILabel(frame: .zero)
    private let tapMarker = MessageRowGestureMarker(frame: .zero)
    private var avatars: [TimelineAvatarView] = []
    private var avatarCount = 0
    private var outgoing = false
    private var visible = false
    private var contentFrames: [CGRect] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 12
        emojiLabel.font = .systemFont(ofSize: 18.5)
        for label in [emojiLabel, countLabel] {
            label.lineBreakMode = .byClipping
            label.isAccessibilityElement = false
            addSubview(label)
        }
        tapMarker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(tapMarker)
        addTarget(self, action: #selector(activate), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TimelineReactionButton, _: UITraitCollection) in
            view.updatePaint()
        }
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ reaction: ReactionSummary, outgoing: Bool, pending: Bool, enabled: Bool,
                   displayScale: CGFloat, mediaContext: AppMediaContext?, contentFrames: [CGRect]) {
        self.contentFrames = contentFrames
        emoji = reaction.emoji
        emojiLabel.text = reaction.emoji
        self.outgoing = outgoing
        isSelected = reaction.reactedByMe == true
        isEnabled = enabled
        alpha = pending ? 0.6 : 1
        if enabled { tapMarker.configure(.tap { [weak self] in self?.activate() }) }
        else { tapMarker.stop() }
        let reactors = reaction.reactors ?? []
        avatarCount = min(5, reactors.count)
        while avatars.count < avatarCount {
            let avatar = TimelineAvatarView(frame: .zero)
            if let last = avatars.last { insertSubview(avatar, belowSubview: last) }
            else { addSubview(avatar) }
            avatar.isAccessibilityElement = false
            avatars.append(avatar)
        }
        for index in avatars.indices {
            let avatar = avatars[index]
            guard index < avatarCount else { avatar.clear(); avatar.isHidden = true; continue }
            let reactor = reactors[index]
            avatar.isHidden = false
            avatar.configure(url: reactor.avatarUrl.flatMap(URL.init(string:)), name: reactor.name ?? "User \(reactor.uid)",
                             userID: reactor.uid, diameter: 23, displayScale: displayScale, mediaContext: mediaContext)
            avatar.isAccessibilityElement = false
            avatar.setVisible(visible)
        }
        if avatarCount > 0, reaction.count > 5 {
            countLabel.text = "+\(reaction.count - 5)"
            countLabel.font = .systemFont(ofSize: 11)
        } else if avatarCount == 0, reaction.count > 1 {
            countLabel.text = "\(reaction.count)"
            countLabel.font = .systemFont(ofSize: 12)
        } else { countLabel.text = nil }
        countLabel.isHidden = countLabel.text == nil
        accessibilityLabel = "\(reaction.emoji), \(reaction.count) reactions"
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        if !enabled { accessibilityTraits.insert(.notEnabled) }
        updatePaint()
        setNeedsLayout()
    }

    func clear() {
        emoji = nil
        emojiLabel.text = nil
        countLabel.text = nil
        onActivate = nil
        avatarCount = 0
        visible = false
        isEnabled = false
        isSelected = false
        tapMarker.stop()
        contentFrames.removeAll(keepingCapacity: true)
        for avatar in avatars { avatar.clear(); avatar.isHidden = true }
        accessibilityLabel = nil
        accessibilityTraits = [.button, .notEnabled]
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        for avatar in avatars { avatar.setVisible(visible && !avatar.isHidden) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        emojiLabel.frame = contentFrames.first ?? .zero
        countLabel.frame = contentFrames.count > 1 ? contentFrames[1] : .zero
        tapMarker.frame = bounds
        for index in avatars.indices {
            avatars[index].frame = index < avatarCount && index + 2 < contentFrames.count ? contentFrames[index + 2] : .zero
        }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, emoji != nil else { return false }
        activate()
        return true
    }

    private func updatePaint() {
        let dark = traitCollection.userInterfaceStyle == .dark
        let foreground = isSelected ? UIColor.white
            : UIColor(ChahuaTheme.ChatBubble.incomingForeground(for: dark ? .dark : .light))
        if outgoing && isSelected { backgroundColor = UIColor(red: 38 / 255, green: 107 / 255, blue: 180 / 255, alpha: 1) }
        else if isSelected { backgroundColor = UIColor(red: 64 / 255, green: 135 / 255, blue: 210 / 255, alpha: 1) }
        else if dark { backgroundColor = UIColor(red: 30 / 255, green: 32 / 255, blue: 35 / 255, alpha: 1) }
        else { backgroundColor = UIColor(red: 215 / 255, green: 216 / 255, blue: 218 / 255, alpha: 1) }
        emojiLabel.textColor = foreground
        countLabel.textColor = foreground.withAlphaComponent(0.7)
        for avatar in avatars {
            avatar.layer.borderWidth = 1
            avatar.layer.borderColor = foreground.cgColor
            avatar.layer.cornerRadius = 11.5
        }
    }

    @objc private func activate() {
        guard isEnabled, emoji != nil else { return }
        onActivate?()
    }
}
#endif
