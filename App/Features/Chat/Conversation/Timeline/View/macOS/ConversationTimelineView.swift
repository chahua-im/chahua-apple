#if os(macOS)
import AppKit
import SwiftUI

/// SwiftUI owns only the application boundary; the complete timeline is native.
struct ConversationTimelineView: NSViewControllerRepresentable {
    @Environment(\.mediaContext) private var mediaContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatHeaderInset) private var chatHeaderInset
    @Environment(\.chatComposerInset) private var chatComposerInset
    @Environment(\.isChatSplitResizing) private var isSplitResizing

    let model: ConversationTimelineModel
    var initialPosition: TimelineInitialPosition = .liveEdge
    var loadsInitialAutomatically = true
    var actions = TimelineBubbleActions()
    var interactionContext = MessageInteractionContext()

    func makeNSViewController(context: Context) -> TimelineViewController {
        let controller = TimelineViewController(model: model)
        configure(controller)
        return controller
    }

    func updateNSViewController(_ controller: TimelineViewController, context: Context) {
        configure(controller)
    }

    private func configure(_ controller: TimelineViewController) {
        controller.configure(
            actions: actions,
            interactionContext: interactionContext,
            mediaContext: mediaContext,
            colorScheme: colorScheme,
            headerInset: chatHeaderInset,
            composerInset: chatComposerInset,
            isSplitResizing: isSplitResizing
        )
        if loadsInitialAutomatically {
            controller.loadInitialIfNeeded(position: initialPosition)
        }
    }

    static func dismantleNSViewController(_ controller: TimelineViewController, coordinator: ()) {
        controller.tearDown()
    }
}
#endif
