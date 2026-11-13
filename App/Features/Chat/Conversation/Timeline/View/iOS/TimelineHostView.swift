#if os(iOS)
    import SwiftUI
    import UIKit
    struct TimelineHostView: UIViewControllerRepresentable {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.chatHeaderInset) private var chatHeaderInset
        @Environment(\.chatComposerInset) private var chatComposerInset
        @Environment(\.isWideChatLayout) private var isWideChatLayout
        @AppStorage(MessageTextSizePreference.storageKey)
        private var messageTextSize = MessageTextSizePreference.defaultValue
        @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
        @Environment(\.conversationDisplayValues) private var displayValues
        private var showAllAvatars: Bool { displayValues.showAllAvatars }
        private var showDmDetails: Bool { displayValues.showDmDetails }
        let model: ConversationTimelineModel
        var actions = TimelineBubbleActions()
        var mediaContext: AppMediaContext?

        func makeUIViewController(context: Context) -> TimelineCollectionViewController {
            let controller = TimelineCollectionViewController(model: model, actions: actions)
            controller.mediaContext = mediaContext
            controller.colorScheme = colorScheme
            controller.messageTextSize = messageTextSize
            controller.appLanguage = appLanguage
            controller.showAllAvatars = showAllAvatars
            controller.showDmDetails = showDmDetails
            controller.isWideChatLayout = isWideChatLayout
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
            controller.appLanguage = appLanguage
            controller.showAllAvatars = showAllAvatars
            controller.showDmDetails = showDmDetails
            controller.isWideChatLayout = isWideChatLayout
            controller.headerInset = chatHeaderInset
            controller.composerInset = chatComposerInset
        }

        static func dismantleUIViewController(
            _ controller: TimelineCollectionViewController, coordinator: ()
        ) {
            controller.tearDown()
        }
    }

#endif
