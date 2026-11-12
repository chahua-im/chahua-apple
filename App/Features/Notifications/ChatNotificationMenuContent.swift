import ChahuaAPI
import SwiftUI

/// The detail-page button and floating-header bell share the same notification choices.
/// Opening either menu leaves settings unchanged; only choosing an item invokes the update.
struct ChatNotificationMenuContent: View {
    let chat: ChatListItem
    let defaults: NotificationSettingsResponse?
    /// Nil means Unmute; the caller resolves account defaults before applying it.
    let onUpdate: (UpdateNotificationSettingRequest?) -> Void

    private var isMuted: Bool {
        chat.notificationMuted(defaults: defaults)
    }

    private var isMutedForever: Bool {
        chat.notificationPermanentlyMuted(defaults: defaults)
            || NotificationMuteDeadline.isIndefinite(chat.mutedUntil)
    }

    var body: some View {
        if isMuted {
            Button("Unmute", systemImage: "bell") { onUpdate(nil) }
        } else {
            Menu("Mute for…", systemImage: "bell.badge") {
                muteDuration("Mute for 1 hour", seconds: 3_600)
                muteDuration("Mute for 8 hours", seconds: 28_800)
                muteDuration("Mute for 1 day", seconds: 86_400)
                muteDuration("Mute for 7 days", seconds: 604_800)
            }
        }
        Menu("Customize", systemImage: "slider.horizontal.3") {
            notificationChoice(
                "Always notify", mode: .alwaysUnmuted, selected: chat.muteOverride == false)
            notificationChoice(
                "Always mute", mode: .alwaysMuted, selected: chat.muteOverride == true)
            notificationChoice(
                "Use account default", mode: .inherit, selected: chat.muteOverride == nil)
        }
        if !isMutedForever {
            Divider()
            Button("Mute forever", systemImage: "bell.slash", role: .destructive) {
                onUpdate(.init(mode: .alwaysMuted))
            }
        }
    }

    private func muteDuration(_ title: LocalizedStringKey, seconds: Int) -> some View {
        Button(title) { onUpdate(.init(mode: .temporarilyMuted, durationSeconds: seconds)) }
    }

    private func notificationChoice(
        _ title: LocalizedStringKey, mode: NotificationSettingMode, selected: Bool
    ) -> some View {
        Button {
            onUpdate(.init(mode: mode))
        } label: {
            HStack {
                Text(title)
                if selected { Image(systemName: "checkmark") }
            }
        }
    }
}
