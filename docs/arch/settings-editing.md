# Explicit-save settings pages

Use this convention for settings menus/pages that edit a draft and commit it with **Save**. Instant-apply settings, such as independent preference toggles, are a separate interaction model; do not mix autosave and explicit Save within the same draft.

Applies to the account-wide **Friend Request Permission**, **Read Receipts**, **Last Seen & Online**, and app-wide **Language** pages. **Friend Privacy** is absent from the peer-profile More menu; the shared per-friend page remains reachable from DM Chat Info and retains its existing instant-save behavior.

## Presentation and draft ownership

- Push into the existing Settings navigation on iOS; do not open a second pop-up sheet. Use a compact, inline title and top-right Save. macOS keeps the existing Settings sidebar/detail hierarchy.
- Keep a local draft and the last successfully loaded or persisted values. Editing must not write to the server or local preferences. Compare against that baseline to determine whether there are unsaved changes; reverting to the baseline removes the dirty state.
- Load and save errors retain a useful Retry action. Do not treat an unavailable or failed initial load as editable default data.

## Save and exit behavior

| State | Save | Back / swipe-back |
| --- | --- | --- |
| Loading or initial load failed | Disabled | Return without writing. |
| Loaded, unchanged | Neutral emphasis; enabled when otherwise valid | Return normally without writing or confirmation. |
| Valid unsaved changes | Solid primary-blue background with contrasting white text | Ask **Discard unsaved changes?**, with **Discard Changes** and **Keep Editing**. |
| Invalid unsaved changes | Disabled; no active blue emphasis | The same discard confirmation; invalid drafts still need exit protection. |
| Saving | Replace Save with a spinner; disable repeat submission and editing | Block exit until the request finishes. Do not present a competing discard prompt. |
| Save failed | Retain the draft and error; allow explicit retry when valid | Preserve dirty-exit protection. |
| Save succeeded | Adopt the confirmed server result or committed local preference | Close/pop the editor and return to its parent. |

Dirty status controls Save emphasis; validity controls whether submission is enabled. Do not introduce a second Apply button. Back never saves. Keep Editing must preserve every draft field. Discard leaves without issuing a write.

Language uses verbatim autonyms (**English**, **简体中文**, **繁體中文**) and a checkmark for the draft selection; **System Default** remains localized. The interface language does not change before Save. Its UserDefaults commit is synchronous: do not invent a network request, failure/retry UI, artificial delay or spinner. Unchanged Language has disabled neutral Save. Account/session replacement discards its open draft, but the committed language remains app-wide.

Protect every applicable exit, not only the visible Back button. While dirty, block outer Settings-sheet dismissal/Close and macOS sidebar changes; the user can choose Save or leave through guarded Back/Escape, which offers discard confirmation. While saving, block all these exits. Fence asynchronous responses by account/session and editor lifetime so an old request cannot close or update another account's editor.

## Native navigation requirement

On iOS, retain UIKit's actual Back item and native interactive swipe-back. Do not substitute a text `Back` button, hide the native item, or disable clean interactive navigation just to implement dirty-form protection.

The shared [SettingsEditorControls](../../App/Features/Notifications/SettingsEditorControls.swift) modifier provides the toolbar, discard alert and exit-protection preference. [SettingsEditorNavigationGuard](../../App/Features/Notifications/iOS/SettingsEditorNavigationGuard.swift) bridges native Back/swipe interception. [FriendVerificationSettingsView](../../App/Features/Social/FriendVerificationSettingsView.swift), [ReadReceiptPrivacySettingsView](../../App/Features/Notifications/ReadReceiptPrivacySettingsView.swift), [PresencePrivacySettingsView](../../App/Features/Notifications/PresencePrivacySettingsView.swift), and [LanguageSettingsView](../../App/Features/Notifications/LanguageSettingsView.swift) retain ownership of their drafts and commits:

- Intercept dirty native Back actions with public `UINavigationItem.backAction`.
- Intercept dirty edge/content pop gestures before transition; clean gestures retain native completion and cancellation.
- Forward the original gesture delegate's decisions and restore installed actions/delegates when leaving. UIKit copies `UIAction`, so compare action identifiers, not object identity, when checking ownership.
- Keep the bridge limited to the active editor. Do not swizzle methods or use private APIs; do not change other Settings pages' navigation.
- Keep draft validation, save/error state, and confirmation handling in shared SwiftUI. The UIKit bridge exists only because native interactive Back interception cannot be expressed by the SwiftUI dismissal guard alone. macOS uses guarded Back/Escape/sidebar navigation rather than an iOS gesture emulation.

This is a behavioral convention and reference implementation, not a requirement to add a generic form framework. Reuse the existing implementation/pattern when another explicit-save page needs it.

## Verification checklist

- Open a loaded page without changes: neutral Save; Back and clean completed/cancelled swipes behave normally; no write occurs.
- Edit a valid value: Save gets a solid primary-blue background and contrasting white text, not a white capsule with blue text. Revert it: Save returns to neutral and exit no longer prompts.
- Make an invalid draft: Save is disabled; Back/swipe still asks before discarding.
- Choose Keep Editing: all values remain. Choose Discard Changes: return without a write.
- Delay a save: spinner appears; repeat Save, editing and all exits are blocked.
- Fail a save: remain on the page with the draft and retry. Succeed on retry: return only after server confirmation.
- Switch account or leave the editor before a delayed response: no stale result changes or closes the new editor.
- After leaving, verify native Back/swipe on another Settings page. Repeat applicable exits in compact and split layouts and on macOS.

The [parity checklist](../pwa-parity-checklist.md) records device sign-off under **S3** (Friend Request Permission), **S5** (Read Receipts / Last Seen & Online), and **R8** (Language).
