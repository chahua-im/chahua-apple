#!/bin/bash
# Run from the release workspace, not the checked-out release-source directory.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

validate() {
  xcrun swift -module-cache-path build/swift-module-cache "$script_dir/validate-macos-release.swift" "$1"
}

case "${1:-}" in
  verify-source)
    : "${MACOS_ZIP_SHA256:?Missing selected ZIP checksum}"
    printf '%s  %s\n' "$MACOS_ZIP_SHA256" 'build/artifacts/Chahua-macOS.zip' | shasum -a 256 -c -
    mkdir -p build/source build/notarized
    mv build/artifacts/Chahua-macOS.zip build/source/Chahua-macOS.zip
    ditto -x -k build/source/Chahua-macOS.zip build/notarized
    codesign --verify --deep --strict build/notarized/Chahua.app
    validate bundle
    ;;
  prepare-tools)
    # The release asset digest is pinned, not obtained from the same download at runtime.
    mkdir -p build/sparkle-tools
    curl --fail --location --proto '=https' --tlsv1.2 \
      --output build/Sparkle-2.10.1.tar.xz \
      https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
    printf '%s  %s\n' '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27' 'build/Sparkle-2.10.1.tar.xz' | shasum -a 256 -c -
    tar -xJf build/Sparkle-2.10.1.tar.xz -C build/sparkle-tools
    test -x build/sparkle-tools/bin/generate_appcast
    ;;
  notarize)
    set +x
    : "${ASC_KEY_FILE:?Missing App Store Connect API key file}"
    : "${ASC_KEY_ID:?Missing App Store Connect API key ID}"
    : "${ASC_ISSUER_ID:?Missing App Store Connect issuer ID}"
    xcrun notarytool submit build/source/Chahua-macOS.zip \
      --key "$ASC_KEY_FILE" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
      --wait --timeout 30m
    xcrun stapler staple build/notarized/Chahua.app
    xcrun stapler validate build/notarized/Chahua.app
    codesign --verify --deep --strict build/notarized/Chahua.app
    ditto -c -k --sequesterRsrc --keepParent build/notarized/Chahua.app \
      build/artifacts/Chahua-macOS-notarized.zip
    ;;
  generate-appcast)
    set +x
    : "${SPARKLE_ED_KEY_FILE:?Missing Sparkle Ed25519 secret file}"
    : "${BUILD_URL:?Missing immutable Jenkins build URL}"
    # No unsigned archive, old feed, deltas, or notes may enter this single-release feed.
    # This internal testing feed intentionally makes no historic minimum-OS support promise.
    test ! -e build/artifacts/Chahua-macOS.zip
    test ! -e build/artifacts/appcast.xml
    validate key
    build/sparkle-tools/bin/generate_appcast \
      --ed-key-file "$SPARKLE_ED_KEY_FILE" --maximum-deltas 0 \
      --download-url-prefix "${BUILD_URL}artifact/build/artifacts/" \
      -o build/artifacts/appcast.xml build/artifacts
    # A key mismatch can merely warn in generate_appcast 2.10.1; independently verify
    # the enclosure signature over the final ZIP using the app's embedded public key.
    validate appcast
    ;;
  *)
    printf 'Usage: %s {verify-source|prepare-tools|notarize|generate-appcast}\n' "$0" >&2
    exit 2
    ;;
esac
