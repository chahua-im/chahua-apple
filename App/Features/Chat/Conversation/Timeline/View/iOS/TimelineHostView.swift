#if os(iOS)
    import SwiftUI
    import UIKit
    struct TimelineHostView: UIViewControllerRepresentable {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.chatHeaderInset) private var chatHeaderInset
        @Environment(\.chatComposerInset) private var chatComposerInset
        @AppStorage(MessageTextSizePreference.storageKey)
        private var messageTextSize = MessageTextSizePreference.defaultValue
        @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
        @AppStorage(ConversationTimelinePreferences.showAllAvatarsStorageKey)
        private var showAllAvatars = ConversationTimelinePreferences.defaultShowAllAvatars
        @AppStorage(ConversationTimelinePreferences.showDmDetailsStorageKey)
        private var showDmDetails = ConversationTimelinePreferences.defaultShowDmDetails
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
            controller.headerInset = chatHeaderInset
            controller.composerInset = chatComposerInset
        }
    }

#endif
