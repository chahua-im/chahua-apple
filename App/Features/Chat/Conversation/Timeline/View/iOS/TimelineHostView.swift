#if os(iOS)
    import SwiftUI
    import UIKit
    struct TimelineHostView: UIViewControllerRepresentable {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.chatHeaderInset) private var chatHeaderInset
        @Environment(\.chatComposerInset) private var chatComposerInset
        @AppStorage(MessageTextSizePreference.storageKey)
        private var messageTextSize = MessageTextSizePreference.defaultValue
        let model: ConversationTimelineModel
        var actions = TimelineBubbleActions()
        var mediaContext: AppMediaContext?

        func makeUIViewController(context: Context) -> TimelineCollectionViewController {
            let controller = TimelineCollectionViewController(model: model, actions: actions)
            controller.mediaContext = mediaContext
            controller.colorScheme = colorScheme
            controller.messageTextSize = messageTextSize
            controller.headerInset = chatHeaderInset
            controller.composerInset = chatComposerInset
            return controller
        }

        func updateUIViewController(
            _ controller: TimelineCollectionViewController, context: Context
        ) {
            controller.mediaContext = mediaContext
            controller.actions = actions
            controller.colorScheme = colorScheme
            controller.messageTextSize = messageTextSize
            controller.headerInset = chatHeaderInset
            controller.composerInset = chatComposerInset
        }
    }

#endif
