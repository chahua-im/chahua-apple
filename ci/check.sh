#!/usr/bin/env bash
set -euo pipefail

# The Jenkins macos executor must provide macOS 26.5+, Xcode 27 with an installed
# iOS 26.5+ simulator runtime, and the Ruby in .ruby-version. Ruby's JSON library
# selects a simulator without installing any tools or relying on a device UUID.
readonly PROJECT='chahua-apple.xcodeproj'
readonly SCHEME='chahua-apple'
readonly BUILD_ROOT="${WORKSPACE:-${PWD}}/.ci"

prepare_build_root() {
  mkdir -p "$BUILD_ROOT"
}

select_ios_destination() {
  xcrun simctl list devices available --json | ruby -rjson -rrubygems -e '
    minimum_version = Gem::Version.new("26.5")
    devices = JSON.parse(STDIN.read).fetch("devices")

    candidates = devices.flat_map do |runtime, runtime_devices|
      match = runtime.match(/\.iOS-(\d+(?:-\d+)*)\z/)
      next [] unless match

      version = Gem::Version.new(match[1].tr("-", "."))
      next [] if version < minimum_version

      runtime_devices.filter_map do |device|
        next unless device["isAvailable"] && device["name"].start_with?("iPhone")

        [version, device["name"], device["udid"]]
      end
    end

    # Prefer the newest installed runtime supported by the selected Xcode.
    version, name, udid = candidates.sort_by { |candidate| candidate }.last
    abort "No available iPhone simulator with iOS 26.5 or newer is installed." unless udid

    warn "Selected #{name} running iOS #{version}."
    puts "platform=iOS Simulator,id=#{udid}"
  '
}

build_first_party_packages() {
  local manifest
  local package_dir
  local package_name

  for manifest in Packages/*/Package.swift; do
    package_dir="${manifest%/Package.swift}"
    package_name="${package_dir##*/}"

    swift build \
      --package-path "$package_dir" \
      --scratch-path "$BUILD_ROOT/SwiftPM/$package_name"
  done
}

test_first_party_packages() {
  local manifest
  local package_dir
  local package_name

  for manifest in Packages/*/Package.swift; do
    package_dir="${manifest%/Package.swift}"
    package_name="${package_dir##*/}"

    # ChahuaAudio currently has no test target; every first-party package is
    # still compiled above, while packages with tests (currently ChahuaAPI) run them.
    if [[ -d "$package_dir/Tests" ]]; then
      swift test \
        --package-path "$package_dir" \
        --scratch-path "$BUILD_ROOT/SwiftPM/$package_name"
    fi
  done
}

compile() {
  local ios_destination

  prepare_build_root
  ios_destination="$(select_ios_destination)"

  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "$ios_destination" \
    -derivedDataPath "$BUILD_ROOT/DerivedData/iOS" \
    -clonedSourcePackagesDirPath "$BUILD_ROOT/SourcePackages" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO

  # Ad-hoc checks cannot use provisioning-only push entitlements. Signed release
  # builds retain Config/macOS.entitlements and exercise real distribution signing.
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -sdk macosx \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_ROOT/DerivedData/macOS" \
    -clonedSourcePackagesDirPath "$BUILD_ROOT/SourcePackages" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_ENTITLEMENTS= \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER=

  build_first_party_packages
}

# Avoid Xcode cloning multiple simulators and competing hosted UI test processes.
test() {
  local ios_destination

  prepare_build_root
  rm -rf "$BUILD_ROOT/TestResults"
  mkdir -p "$BUILD_ROOT/TestResults"
  ios_destination="$(select_ios_destination)"

  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "$ios_destination" \
    -derivedDataPath "$BUILD_ROOT/DerivedData/iOS" \
    -parallel-testing-enabled NO \
    -clonedSourcePackagesDirPath "$BUILD_ROOT/SourcePackages" \
    -resultBundlePath "$BUILD_ROOT/TestResults/chahua-ios.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO

  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -sdk macosx \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_ROOT/DerivedData/macOS" \
    -clonedSourcePackagesDirPath "$BUILD_ROOT/SourcePackages" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$BUILD_ROOT/TestResults/chahua-macos.xcresult" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_ENTITLEMENTS= \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER=

  test_first_party_packages
}

case "${1:-}" in
  compile)
    compile
    ;;
  test)
    test
    ;;
  style)
    bash "$(dirname -- "${BASH_SOURCE[0]}")/../format.sh" --check
    ;;
  *)
    echo "usage: $0 {compile|test|style}" >&2
    exit 64
    ;;
esac
