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

4. **Understand the automation tool.** Fastlane is the project's iOS automation tool; this project uses its Match integration to retrieve code-signing assets.

5. **Sync development signing.** The development sync lane is read-only: it fetches the existing development signing profile and certificate assets without changing Apple or the Match repository. Before running it, ask the project owner for the Match encryption password. Provide that password when Fastlane prompts for it, then run:

   ```sh
   bundle exec fastlane ios sync_development_signing
   ```
