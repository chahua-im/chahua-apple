# Notifications and sharing

[Documentation index](../README.md)

## Notification preferences

Chat-list swipe actions open the full **Notification settings** chooser: **Use account default**, **Always notify**, **Always mute**, and temporary mutes for **1 hour**, **8 hours**, **1 day**, or **7 days**. Temporary mute takes precedence, then expires back to the saved exception or account default; it does not clear unread state or change archive membership. Temporary choices are hidden when the underlying preference already mutes the chat.

The group/DM information **Mute** action opens a native popup menu, not a sheet. **Mute for…** opens a submenu with the same four preset durations; **Customize** offers **Always notify**, **Always mute**, and **Use account default**, with a checkmark on the saved choice. Below a separator, red **Mute forever** is a shortcut for Always mute. When the chat is already muted, **Unmute** replaces Mute for…; it saves Always notify if that chat kind's account default is muted, otherwise Use account default. Both paths clear the temporary mute. Failed updates show an error with Retry.

The detail action tile itself expresses the current state: **Mute** when notifying, **Unmute** for an indefinite mute (including the `9999-12-31` sentinel), or **until HH:mm**, **until tomorrow**, or **until MM/DD** for a finite mute. Date comparisons use local calendar days, including daylight-saving transitions, and times use the 24-hour clock. There is no separate status caption or expiry note; the muted tile still opens the menu containing Unmute.

Detail-menu verification: in both DM and group information, confirm duration and Customize choices open as popup submenus, and Mute forever is red. Temporarily mute a chat with an account default of On, then Unmute: the chat should notify with no exception. Repeat with an account default of Off: Unmute should create an Always notify exception. Confirm Mute forever and Customize → Always mute produce the same state.

**Settings → Push Notifications** separates the device's **Enable Push Notifications** switch from the **Notification Settings** group, whose **Direct messages / Groups** rows show each account default as On/Off. Open a category to manage its default and server-counted exception list. Exceptions support search when adding from active or archived chats, paging, individual removal, and confirmed bulk removal. Changes synchronize across clients; reconnect refreshes defaults, and a single nearest-expiry timer updates mute indicators without polling. Tap the push-switch row five times consecutively to reveal **Debug** authorization, APNs, registration details, and recovery actions; leaving the page hides them again. Permission-denied help and operation errors remain visible without unlocking Debug.

Tap an individual exception to edit it; the exception list has no inline Remove action. The detail sheet offers **Remove from exceptions**, then **Notifications → Always On / Always Off** with a checkmark on the draft selection. **X** cancels without saving; the toolbar **checkmark** saves. Removal immediately restores the account default and closes the sheet.

**Add exception** lists chats with a 40-point avatar and display name, using the same avatar fallback as the existing exception list. The entire row remains clickable; search and adding behavior are unchanged. Manually check DM and group rows, including a chat without an avatar.

Manual verification: disable a category default, add an **Always notify** exception, temporarily mute it, and confirm expiry restores notifications without changing archive or unread state. Change the same preferences in the PWA, reconnect Apple, and check the list/header and exception counts. Remove an exception and then all exceptions; each chat should return to its category default.

UI smoke verification: check the Read Receipts Exceptions placeholder on iOS and macOS; confirm Push Notifications has two separate groups and category navigation still works. Tap the push row four times (Debug stays hidden), then a fifth time (Debug appears); leave and reopen the page to confirm it hides again. Use the switch itself to enable/disable device push registration.

Exception editor verification: open an Always Off exception, select Always On, and cancel with X; reopening must still show Always Off. Select Always On again and save with the checkmark; the list and reopened detail should reflect it. Remove the exception from its detail and confirm it disappears from the list. In chat detail, check the button shows a finite deadline in the correct format, Unmute for an indefinite mute, and Mute after expiry; no expiry note should appear.

## System integrations

- iOS and macOS message notifications offer **Reply**. The server must send `aps.category: "chahua"`; the separate routing envelope remains unchanged. Replies target the notification's chat/thread through the account-scoped outbox without consuming the open composer draft.
- On iOS, **Take Photo** is available from the attachment menu and attachment preview menu. Capture returns to the existing media preview for an explicit Send; cancellation preserves the draft. Camera access requires a physical device and permission. macOS retains Photos and Files.
- The iOS **Chahua** Share extension accepts text, web links, images, and videos in one unified sheet. Its media preview sits above a searchable grid of recent writable chat and thread avatars; the caption and **Send** stay on that screen with a single destination and no push navigation. Content uploads while the destination is being prepared. Sending replaces the card with a gapped activity ring, then a success checkmark before the share flow dismisses. macOS does not ship a Share extension.
- Failed content acquisition blocks sending rather than silently omitting items. A failed message request retains its destination and idempotency ID for retry.
- Image compression defaults on in the app and Share extension, using the shared [still-image preparation policy](outbound-queue.md#native-preparation-and-durable-files). The app offers **Compress images** in Media options; the Share sheet shows the toggle beside the caption. Turning it off uploads the imported/provider source bytes. Changing it in the Share sheet cancels and replaces previous preparation/uploads before Send becomes available. Animated images and videos retain their original bytes.

The iOS app and extension share the session token through Keychain Sharing, not a shared plaintext file. Open the updated iOS app once to migrate an existing session before using the extension. Register `app.chahua.chat.share` only for iOS and refresh the iOS host/extension provisioning profiles with access to `$(AppIdentifierPrefix)app.chahua.chat.shared`; macOS signing requires only the app profile. Fastlane's iOS signing lanes include both identifiers, while its macOS lanes include only `app.chahua.chat`. Distribution signing and physical-device APNs/camera/share verification require those profiles.

Manual verification:

1. Leave a draft in a chat/thread, reply to its notification while Chahua is backgrounded or cold, and verify delivery to that destination without changing the draft.
2. Capture a photo from each attachment entry point, then exercise cancellation and denied camera permission; nothing should send before confirmation.
3. On iOS, from another app, share a link, text, a photo, and a video. Confirm the unified sheet keeps the preview, search/recent destination grid, caption, and Send together; exercise both chat and thread destinations, offline retry, and sign-out/account switching. For images, verify **Compress images** starts on, then toggle it before and during upload; Send must wait for the current setting, and disabling compression must preserve the provider bytes. Include a long screenshot, a transparent PNG and an animated image. Confirm the sent content in the destination and the brief success check before dismissal.

