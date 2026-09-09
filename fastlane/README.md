fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios sync_development_signing

```sh
[bundle exec] fastlane ios sync_development_signing
```

Fetch iOS development signing assets without modifying Apple or the Match repository

### ios sync_distribution_signing

```sh
[bundle exec] fastlane ios sync_distribution_signing
```

Fetch iOS App Store signing assets without modifying Apple or the Match repository

### ios bootstrap_development_signing

```sh
[bundle exec] fastlane ios bootstrap_development_signing
```

Create or repair iOS development signing assets; intentionally mutable

### ios bootstrap_distribution_signing

```sh
[bundle exec] fastlane ios bootstrap_distribution_signing
```

Create or repair iOS App Store signing assets; intentionally mutable

----


## Mac

### mac sync_development_signing

```sh
[bundle exec] fastlane mac sync_development_signing
```

Fetch macOS development signing assets without modifying Apple or the Match repository

### mac sync_distribution_signing

```sh
[bundle exec] fastlane mac sync_distribution_signing
```

Fetch macOS Developer ID signing assets without modifying Apple or the Match repository

### mac bootstrap_development_signing

```sh
[bundle exec] fastlane mac bootstrap_development_signing
```

Create or repair macOS development signing assets; intentionally mutable

### mac bootstrap_distribution_signing

```sh
[bundle exec] fastlane mac bootstrap_distribution_signing
```

Create or repair macOS Developer ID signing assets; intentionally mutable

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
