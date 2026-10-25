/// Persisted identity presentation shared by live timelines and captured records.
enum ConversationTimelinePreferences {
    static let showAllAvatarsStorageKey = "chat.timeline.showAllAvatars"
    static let showDmDetailsStorageKey = "chat.timeline.showDmDetails"

    static let defaultShowAllAvatars = false
    static let defaultShowDmDetails = true
}
