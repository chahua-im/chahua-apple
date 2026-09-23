#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "$0")"

case "${1:-}" in
  '') set -- format --in-place ;;
  --check) set -- lint --strict ;;
  *) echo "usage: $0 [--check]" >&2; exit 64 ;;
esac

xcrun swift-format "$@" --recursive \
  App Tests Packages/*/Package.swift Packages/*/Sources Packages/*/Tests
