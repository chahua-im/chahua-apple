#if os(macOS)
    import AppKit
    import SwiftUI

    /// SwiftUI owns only the application boundary; the complete timeline is native.
    struct ConversationTimelineView: NSViewControllerRepresentable {
        @Environment(\.mediaContext) private var mediaContext
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.chatComposerInset) private var chatComposerInset
        @Environment(\.isChatSplitResizing) private var isSplitResizing
        @Environment(\.isWideChatLayout) private var isWideChatLayout
        @AppStorage(MessageTextSizePreference.storageKey)
        private var messageTextSize = MessageTextSizePreference.defaultValue
        @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
        @AppStorage(ConversationListPreferences.unreadBadgeColorStorageKey)
        private var unreadBadgeColorRawValue = ConversationListPreferences.defaultUnreadBadgeColor
            .rawValue
        @AppStorage(ConversationTimelinePreferences.showAllAvatarsStorageKey)
        private var showAllAvatars = ConversationTimelinePreferences.defaultShowAllAvatars
        @AppStorage(ConversationTimelinePreferences.showDmDetailsStorageKey)
        private var showDmDetails = ConversationTimelinePreferences.defaultShowDmDetails
        let model: ConversationTimelineModel
        var initialPosition: TimelineInitialPosition = .liveEdge
        var loadsInitialAutomatically = true
        var actions = TimelineBubbleActions()
        var interactionContext = MessageInteractionContext()

        private var unreadBadgeColor: ConversationUnreadBadgeColor {
            ConversationUnreadBadgeColor(rawValue: unreadBadgeColorRawValue)
                ?? ConversationListPreferences.defaultUnreadBadgeColor
        }

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
                messageTextSize: messageTextSize,
                appLanguage: appLanguage,
                showAllAvatars: showAllAvatars,
                showDmDetails: showDmDetails,
                unreadBadgeColor: unreadBadgeColor,
                composerInset: chatComposerInset,
                isSplitResizing: isSplitResizing,
                isWideChatLayout: isWideChatLayout
            )
            if loadsInitialAutomatically {
                controller.loadInitialIfNeeded(position: initialPosition)
            }
        }

        static func dismantleNSViewController(_ controller: TimelineViewController, coordinator: ())
        {
            controller.tearDown()
        }
    }
#endif
