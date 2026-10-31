import SwiftUI

struct TimelineLayoutEnvironment: Hashable {
    let timelineWidth: CGFloat
    let displayScale: CGFloat
    let bodySize: CGFloat
    let captionSize: CGFloat
    let caption2Size: CGFloat
    let avatarSize: CGFloat
    let localeIdentifier: String
    let timeZoneIdentifier: String
    let layoutDirection: LayoutDirection
    /// In-app language selection: presentation strings localize through it, not the locale.
    let language: String
    let showAllAvatars: Bool
    let showsMessageDetails: Bool
    /// Part of the native measurement/cache identity, independent of the pane width.
    let isWideChatLayout: Bool

    var rowHorizontalInset: CGFloat {
        isWideChatLayout ? 24 : TimelineRowMetrics.rowHorizontalInset
    }

    /// Hidden DM identities reclaim both avatar lanes, including their gaps.
    var identityLaneWidth: CGFloat {
        showsMessageDetails ? avatarSize + TimelineRowMetrics.laneGap : 0
    }

    var centralWidth: CGFloat {
        max(
            0,
            timelineWidth - 2 * rowHorizontalInset - 2 * identityLaneWidth)
    }

    var maximumBubbleWidth: CGFloat {
        isWideChatLayout ? min(620, centralWidth) : centralWidth
    }

    static func current(
        timelineWidth: CGFloat, displayScale: CGFloat = 2, bodySize: CGFloat = 17,
        captionSize: CGFloat = 12, caption2Size: CGFloat = 11, avatarSize: CGFloat = 36,
        locale: Locale = .current, timeZone: TimeZone = .current,
        layoutDirection: LayoutDirection = .leftToRight,
        language: String = AppLanguage.selected.rawValue,
        showAllAvatars: Bool = ConversationTimelinePreferences.defaultShowAllAvatars,
        showsMessageDetails: Bool = true,
        isWideChatLayout: Bool = false
    ) -> Self {
        .init(
            timelineWidth: timelineWidth, displayScale: displayScale, bodySize: bodySize,
            captionSize: captionSize, caption2Size: caption2Size, avatarSize: avatarSize,
            localeIdentifier: locale.identifier, timeZoneIdentifier: timeZone.identifier,
            layoutDirection: layoutDirection, language: language,
            showAllAvatars: showAllAvatars, showsMessageDetails: showsMessageDetails,
            isWideChatLayout: isWideChatLayout)
    }
}
