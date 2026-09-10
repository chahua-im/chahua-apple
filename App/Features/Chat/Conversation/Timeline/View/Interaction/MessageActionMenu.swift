import ChahuaAPI
import SwiftUI

/// Presentation-free content. The timeline owns anchoring, preview, and dismissal.
struct MessageActionMenu<Preview: View>: View {
    let row: TimelineMessageRow
    let context: MessageInteractionContext
    let isReacting: Bool
    let onReaction: (String) -> Void
    let onAction: (MessageMenuAction) -> Void
    let onClose: () -> Void
    @ViewBuilder let preview: () -> Preview

    @AppStorage(MessageReactionPreferences.recentStorageKey)
    private var recentStorage = MessageReactionPreferences.defaultRecentStorage

    private var policy: MessageActionPolicy { .init(row: row, context: context) }
    private var eligibility: MessageReactionEligibility {
        .init(
            canReact: policy.canReact, isReacting: isReacting,
            reactions: row.entry.remoteMessage?.reactions ?? [])
    }

    var body: some View {
        VStack(alignment: row.isOutgoing ? .trailing : .leading, spacing: 8) {
            if policy.canReact {
                reactionStrip
            }
            preview()
            if !policy.actions.isEmpty {
                actionGrid
            }
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message actions")
    }

    private var reactionStrip: some View {
        HStack(spacing: 2) {
            ForEach(MessageReactionPreferences.quick(from: recentStorage), id: \.self) { emoji in
                MessageReactionButton(emoji: emoji, name: emoji, eligibility: eligibility) {
                    react(emoji)
                }
            }
            Button {} label: {
                Image(systemName: "plus")
                    .font(.system(size: 21, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.4)
            .accessibilityLabel("More reactions")
            .accessibilityHint("Not implemented yet")
            .help("Not implemented yet")
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            if isReacting {
                ProgressView().controlSize(.small).allowsHitTesting(false)
                    .accessibilityLabel("Updating reaction")
            }
        }
    }

    private var actionGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 5), spacing: 0) {
            ForEach(policy.actions) { action in
                let enabled = policy.availability(of: action) == .enabled
                Button(role: action == .delete ? .destructive : nil) {
                    guard enabled else { return }
                    onAction(action)
                    onClose()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 21))
                        Text(action.label(hasAttachments: row.entry.remoteMessage?.hasAttachments == true))
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .padding(.horizontal, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(action == .delete ? Color.red : Color.primary)
                .opacity(enabled ? 1 : 0.4)
                .disabled(!enabled)
                .accessibilityHint(enabled ? Text("") : Text("Not implemented yet"))
                .help(
                    enabled
                        ? action.label(hasAttachments: row.entry.remoteMessage?.hasAttachments == true)
                        : String(localized: "Not implemented yet"))
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func react(_ emoji: String) {
        guard eligibility.canToggle(emoji) else { return }
        if !eligibility.isSelected(emoji) {
            recentStorage = MessageReactionPreferences.recording(emoji, in: recentStorage)
        }
        onReaction(emoji)
        onClose()
    }
}

extension MessageMenuAction {
    fileprivate var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .copyLink: "link"
        case .reply: "arrowshape.turn.up.left"
        case .thread: "bubble.left.and.bubble.right"
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .edit: "pencil"
        case .delete: "trash"
        case .save: "bookmark"
        case .favorite: "star"
        case .reactionDetails: "face.smiling"
        }
    }

    fileprivate func label(hasAttachments: Bool) -> String {
        switch self {
        case .copy: hasAttachments ? String(localized: "Copy Text") : String(localized: "Copy")
        case .copyLink: String(localized: "Copy Link")
        case .reply: String(localized: "Reply")
        case .thread: String(localized: "Thread")
        case .pin: String(localized: "Pin")
        case .unpin: String(localized: "Unpin")
        case .edit: String(localized: "Edit")
        case .delete: String(localized: "Delete")
        case .save: String(localized: "Save")
        case .favorite: String(localized: "Favorite")
        case .reactionDetails: String(localized: "Reactions")
        }
    }
}

struct MessageReactionButton: View {
    let emoji: String
    let name: String
    let eligibility: MessageReactionEligibility
    let onSelect: () -> Void

    var body: some View {
        let selected = eligibility.isSelected(emoji)
        let enabled = eligibility.canToggle(emoji)
        Button(action: onSelect) {
            Text(verbatim: emoji)
                .font(.system(size: 26))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .background(.background, in: Circle())
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(
            selected
                ? String(localized: "Remove reaction: \(name)")
                : String(localized: "React with: \(name)")
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(name)
    }
}
