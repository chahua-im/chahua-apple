#if os(iOS)
import ChahuaAPI
import SwiftUI

/// Presentation-free content. The timeline owns anchoring, preview, and dismissal.
struct MessageActionMenu: View {
    enum Section { case reactions, actions }
    let row: TimelineMessageRow
    let context: MessageInteractionContext
    let isReacting: Bool
    let onReaction: (String) -> Void
    let onAction: (MessageMenuAction) -> Void
    let onClose: () -> Void
    var controlsWidth: CGFloat = 276
    let section: Section

    @AppStorage(MessageReactionPreferences.recentStorageKey)
    private var recentStorage = MessageReactionPreferences.defaultRecentStorage
    @ScaledMetric(relativeTo: .caption2) private var actionRowHeight: CGFloat = 63

    private var policy: MessageActionPolicy { .init(row: row, context: context) }
    private var eligibility: MessageReactionEligibility {
        .init(
            canReact: policy.canReact, isReacting: isReacting,
            reactions: row.entry.remoteMessage?.reactions ?? [])
    }

    var body: some View {
        Group {
            switch section {
            case .reactions:
                if policy.canReact { reactionStrip }
            case .actions:
                if !policy.actions.isEmpty { actionGrid }
            }
        }
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
            Button {
            } label: {
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
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: controlsWidth)
        .background(MessageMenuSurface(shape: Capsule()))
        .overlay {
            if isReacting {
                ProgressView().controlSize(.small).allowsHitTesting(false)
                    .accessibilityLabel("Updating reaction")
            }
        }
    }

    private var actionGrid: some View {
        let menuActions = policy.actions
        let rowCount = (menuActions.count + 4) / 5
        return VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { rowIndex in
                if rowIndex > 0 {
                    Divider()
                }
                HStack(spacing: 0) {
                    ForEach(menuActions[(rowIndex * 5)..<min((rowIndex + 1) * 5, menuActions.count)]) { action in
                        actionButton(action)
                            .frame(width: controlsWidth / 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: controlsWidth)
        .background(MessageMenuSurface(shape: RoundedRectangle(cornerRadius: 14)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func actionButton(_ action: MessageMenuAction) -> some View {
        let enabled = policy.availability(of: action) == .enabled
        return Button(role: action == .delete ? .destructive : nil) {
            guard enabled else { return }
            onAction(action)
            onClose()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.symbol)
                    .font(.system(size: 22))
                Text(action.label(hasAttachments: row.entry.remoteMessage?.hasAttachments == true))
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: actionRowHeight)
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

    private func react(_ emoji: String) {
        guard eligibility.canToggle(emoji) else { return }
        if !eligibility.isSelected(emoji) {
            recentStorage = MessageReactionPreferences.recording(emoji, in: recentStorage)
        }
        onReaction(emoji)
        onClose()
    }
}

/// Keep native translucency, but prevent the dimmed backdrop from tinting the controls gray.
private struct MessageMenuSurface<S: InsettableShape>: View {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        shape.fill(.regularMaterial)
            .overlay {
                shape.fill(colorScheme == .dark ? Color(white: 0.12).opacity(0.65) : Color.white.opacity(0.65))
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
                .font(.system(size: 24))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(MessageReactionButtonStyle())
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

private struct MessageReactionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear, in: Circle())
    }
}


#endif
