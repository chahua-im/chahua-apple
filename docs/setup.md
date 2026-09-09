# Development setup

Follow these steps to prepare the Ruby and Fastlane tooling used by the project.

1. **Install and initialize rbenv.** Follow the [official rbenv installation instructions](https://github.com/rbenv/rbenv#installation), then install rbenv and Ruby builds with Homebrew and initialize it in your shell:

   ```sh
   brew install rbenv ruby-build
   rbenv init
   ```

   Complete any shell configuration step printed by `rbenv init`, then open a new shell (or reload your shell configuration).

2. **Install the repository's Ruby version.** From the repository root, install the version declared in `.ruby-version` and make sure rbenv selects it:

   ```sh
   rbenv install "$(cat .ruby-version)"
   rbenv local "$(cat .ruby-version)"
   ```

3. **Install Ruby dependencies.**

   ```sh
   bundle install
   ```

4. **Understand the automation tool.** Fastlane is the project's iOS and macOS automation tool; this project uses its Match integration to retrieve code-signing assets. Signing lanes are separate: `ios` handles iOS, and `mac` handles native macOS. Commands without a platform default to iOS.

5. **Sync development signing.** Each development sync lane is read-only: it fetches existing development profiles and certificates for the selected platform without changing Apple or the Match repository. Before running it, ask the project owner for the Match encryption password and ensure SSH access to the signing repository. Provide that password when Fastlane prompts for it. Run the command for the platform you are developing, or both if needed:

   ```sh
   bundle exec fastlane ios sync_development_signing
   bundle exec fastlane mac sync_development_signing
   ```

## Signing and direct macOS distribution

Both platforms use bundle ID `app.chahua.chat` and team `9422PL3GFR`. Development assets remain in `fastlane-development`; distribution assets remain in `fastlane-distribution`.

| Command (`bundle exec fastlane …`) | Signing assets | Remote changes |
| --- | --- | --- |
| `ios sync_development_signing` | iOS Development | None |
| `mac sync_development_signing` | macOS Development | None |
| `ios sync_distribution_signing` | iOS App Store | None |
| `mac sync_distribution_signing` | macOS Developer ID | None |
| `ios bootstrap_development_signing` | iOS Development | Create or repair |
| `mac bootstrap_development_signing` | macOS Development | Create or repair |
| `ios bootstrap_distribution_signing` | iOS App Store | Create or repair |
| `mac bootstrap_distribution_signing` | macOS Developer ID | Create or repair |

If a read-only sync reports missing or expired assets, a signing maintainer must run the corresponding bootstrap lane with Apple Developer access and write access to the signing repository. Creating Developer ID certificates requires appropriate Apple account permissions; use the Account Holder account if Apple requires it. macOS development profiles also require the development Mac to be registered with the team.

Each lane operates only on its selected platform. Missing macOS assets do not block iOS signing, and running a macOS bootstrap does not also bootstrap iOS.

Xcode uses manual macOS signing:

| Build configuration | Identity | Provisioning profile |
| --- | --- | --- |
| Debug / Local | Apple Development | `match Development app.chahua.chat macos` |
| Release | Developer ID Application | `match Direct app.chahua.chat macos` |

Run `bundle exec fastlane mac sync_development_signing` before building macOS Debug or Local; run `bundle exec fastlane mac sync_distribution_signing` before building macOS Release. iOS signing settings are unchanged. macOS sandboxing and hardened runtime remain enabled.

These lanes manage signing assets only. Public direct-download releases still need packaging, notarization, and stapling; those steps are not automated here. No installer certificate is requested because `.pkg` distribution is not configured.
