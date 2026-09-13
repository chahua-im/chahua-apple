import Combine
import SwiftUI

struct TimelineRowBinding {
    let presentation: TimelineRowPresentation
    let layout: TimelineRowLayout
    let context: TimelineRowContext
    let actions: TimelineBubbleActions
    let mediaContext: AppMediaContext?

    func hasSameRendering(as other: Self) -> Bool {
        presentation.row == other.presentation.row
            && presentation.layoutKey == other.presentation.layoutKey
            && presentation.environment == other.presentation.environment
            && context == other.context
            && mediaContext === other.mediaContext
            && actions.hasSameRendering(as: other.actions)
    }
}

@MainActor
final class TimelineRowHostState: ObservableObject {
    @Published private(set) var binding: TimelineRowBinding?

    func bind(_ binding: TimelineRowBinding) {
        guard self.binding?.hasSameRendering(as: binding) != true else { return }
        self.binding = binding
    }

    func clear() {
        binding = nil
    }
}

struct TimelineRowHostView: View {
    @ObservedObject var state: TimelineRowHostState

    var body: some View {
        if let binding = state.binding {
            TimelineBubbleView(
                presentation: binding.presentation,
                layout: binding.layout,
                context: binding.context,
                actions: binding.actions,
                mediaContext: binding.mediaContext
            )
            .frame(width: binding.layout.size.width, height: binding.layout.size.height, alignment: .topLeading)
            .id(binding.presentation.row.id)
        } else {
            Color.clear
        }
    }
}

extension TimelineBubbleActions {
    func hasSameRendering(as other: Self) -> Bool {
        (openMedia == nil) == (other.openMedia == nil)
            && (openReply == nil) == (other.openReply == nil)
            && (replyToMessage == nil) == (other.replyToMessage == nil)
            && (editMessage == nil) == (other.editMessage == nil)
            && (openThread == nil) == (other.openThread == nil)
            && (openLink == nil) == (other.openLink == nil)
            && (openMention == nil) == (other.openMention == nil)
            && (openFailedMessage == nil) == (other.openFailedMessage == nil)
            && (openContextMenu == nil) == (other.openContextMenu == nil)
            && (toggleReaction == nil) == (other.toggleReaction == nil)
            && (blockPendingMessage == nil) == (other.blockPendingMessage == nil)
            && (revokePendingMessage == nil) == (other.revokePendingMessage == nil)
            && pendingReactionMessageIDs == other.pendingReactionMessageIDs
            && currentUserProfile == other.currentUserProfile
            && modifiablePendingMessageIDs == other.modifiablePendingMessageIDs
            && interactionContext == other.interactionContext
    }
}
