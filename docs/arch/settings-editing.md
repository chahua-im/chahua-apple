# Explicit-save settings pages

Use this convention for settings menus/pages that edit a draft and commit it with **Save**. Instant-apply settings, such as independent preference toggles, are a separate interaction model; do not mix autosave and explicit Save within the same draft.

Applies to the account-wide **Friend Request Permission**, **Read Receipts**, **Last Seen & Online**, and app-wide **Language** pages. **Friend Privacy** is absent from the peer-profile More menu; the shared per-friend page remains reachable from DM Chat Info and retains its existing instant-save behavior.

## Presentation and draft ownership

- macOS and regular-width iPad use the shared `SettingsSplitNavigationView`: account summary and categories on the left, page content on the right, Close at the top and Sign out at the bottom. macOS uses denser rows and a 268pt sidebar; iPad uses touch-sized rows and a 300pt sidebar. Narrow presentations reduce the sidebar width.
- Compact iOS pushes into the existing Settings navigation; do not open a second pop-up sheet. Retain its inline title and native Back/swipe navigation.
- The settings list ends with a centered, secondary-grey `version (build)` footer sourced from `AppConfiguration.version` (the bundle's `CFBundleShortVersionString` and `CFBundleVersion`). On macOS it is the final item inside the scrollable category area, above the separately pinned Sign out region. iPad keeps it below the pinned Sign out row; compact iOS uses that section's footer. It is informational, not another settings destination.
- Keep a local draft and the last successfully loaded or persisted values. Editing must not write to the server or local preferences. Compare against that baseline to determine whether there are unsaved changes; reverting to the baseline removes the dirty state.
- Load and save errors retain a useful Retry action. Do not treat an unavailable or failed initial load as editable default data.

## Save and exit behavior

| State | Save | Compact iOS Back / swipe-back |
| --- | --- | --- |
| Loading or initial load failed | Disabled | Return without writing. |
| Loaded, unchanged | Disabled; hidden on macOS split, neutral on iPad/compact iOS | Return normally without writing or confirmation. |
| Valid unsaved changes | Solid primary-blue background with contrasting white text | Ask **Discard unsaved changes?**, with **Discard Changes** and **Keep Editing**. |
| Invalid unsaved changes | Disabled; no active blue emphasis | The same discard confirmation; invalid drafts still need exit protection. |
| Saving | Replace Save with a spinner; disable repeat submission and editing | Block exit until the request finishes. Do not present a competing discard prompt. |
| Save failed | Retain the draft and error; allow explicit retry when valid | Preserve dirty-exit protection. |
| Save succeeded | Adopt the confirmed server result or committed local preference | Stay on the selected split-layout page; pop compact iOS back to its parent. |

macOS split editors show a 52pt bottom bar only while dirty: **Unsaved changes**, **Revert**, and **Save**. Revert restores the last confirmed baseline without a write and removes the bar. iPad keeps Save in the top-right header, neutral and disabled when clean, blue when dirty. Compact iOS retains its toolbar Save. Do not introduce a second Apply button; Back never saves.

Language uses verbatim autonyms (**English**, **简体中文**, **繁體中文**) and a checkmark for the draft selection; **System Default** remains localized. The interface language does not change before Save. Its UserDefaults commit is synchronous: do not invent a network request, failure/retry UI, artificial delay or spinner. Unchanged Language has disabled neutral Save. Account/session replacement discards its open draft, but the committed language remains app-wide.

Protect every applicable exit. While dirty or saving, split layouts block category changes, Sign out, Close and outer sheet dismissal; macOS offers Revert, while iPad can restore the original selection or Save. Compact iOS Back/swipe asks before discarding dirty changes and blocks exit while saving. Keep Editing preserves the draft; Discard leaves without writing. Fence asynchronous responses by account/session and editor lifetime so an old request cannot close or update another account's editor.

## Native navigation requirement

On compact iOS, retain UIKit's actual Back item and native interactive swipe-back. Do not substitute a text `Back` button, hide the native item, or disable clean interactive navigation just to implement dirty-form protection.

The shared [SettingsEditorControls](../../App/Features/Notifications/SettingsEditorControls.swift) modifier provides platform save controls, the compact-navigation discard alert and the exit-protection preference. [SettingsEditorNavigationGuard](../../App/Features/Notifications/iOS/SettingsEditorNavigationGuard.swift) bridges native Back/swipe interception only in compact navigation. [FriendVerificationSettingsView](../../App/Features/Social/FriendVerificationSettingsView.swift), [ReadReceiptPrivacySettingsView](../../App/Features/Notifications/ReadReceiptPrivacySettingsView.swift), [PresencePrivacySettingsView](../../App/Features/Notifications/PresencePrivacySettingsView.swift), and [LanguageSettingsView](../../App/Features/Notifications/LanguageSettingsView.swift) retain ownership of their drafts and commits:

- Intercept dirty native Back actions with public `UINavigationItem.backAction`.
- Intercept dirty edge/content pop gestures before transition; clean gestures retain native completion and cancellation.
- Forward the original gesture delegate's decisions and restore installed actions/delegates when leaving. UIKit copies `UIAction`, so compare action identifiers, not object identity, when checking ownership.
- Keep the bridge limited to the active editor. Do not swizzle methods or use private APIs; do not change other Settings pages' navigation.
- Keep draft validation, save/error state, and confirmation handling in shared SwiftUI. The UIKit bridge exists only because native interactive Back interception cannot be expressed by the SwiftUI dismissal guard alone; split layouts do not emulate phone gestures.

This is a behavioral convention and reference implementation, not a requirement to add a generic form framework. Reuse the existing implementation/pattern when another explicit-save page needs it.

## Sign-out confirmation

Sign out presents a native confirmation alert naming the account. Cancel does nothing; only the destructive confirmation invokes sign-out. The request is scoped to its account/session and is dismissed on account/session replacement. While signing out or unregistering notifications, repeat requests are disabled. The button owns its confirmation state so it works inside either platform's settings scaffold.

Compact iOS leaves Sign out label sizing to the standard List row instead of adding a 44pt label minimum on top of native row insets. The standalone iPad sidebar button retains a 44pt target without extra vertical padding; macOS keeps its desktop sizing.

## Verification checklist

- Open a loaded page without changes: Save is absent on macOS split and neutral/disabled on iPad and compact iOS; clean navigation performs no write.
- Edit a value: macOS shows the save bar; iPad/compact iOS Save becomes blue. Revert on macOS restores the confirmed selection without writing. Returning a selection to its baseline removes the dirty state.
- Make an invalid draft: Save is disabled; Back/swipe still asks before discarding.
- Choose Keep Editing: all values remain. Choose Discard Changes: return without a write.
- Delay a save: spinner appears; repeat Save, editing and all exits are blocked.
- Fail a save: remain on the page with the draft and retry. Succeed on retry: split layouts remain on the page with clean controls; compact iOS returns only after server confirmation.
- Switch account or leave the editor before a delayed response: no stale result changes or closes the new editor.
- In split layouts, verify dirty/saving drafts block category switching, Sign out, Close and sheet dismissal. After leaving compact editors, verify native Back/swipe still works on another Settings page.
- Open Sign out, cancel, reopen and confirm: cancellation must preserve the session, and confirmation must execute exactly once.

The [parity checklist](../pwa-parity-checklist.md) records device sign-off under **S3** (Friend Request Permission), **S5** (Read Receipts / Last Seen & Online), and **R8** (Language).
