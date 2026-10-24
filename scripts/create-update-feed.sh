#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The caller supplies a private-key file, never a key as a command-line argument.
: "${SPARKLE_KEY_FILE:?Set SPARKLE_KEY_FILE to the signing key file}"
: "${VCODE_RELEASE_TAG:?Set VCODE_RELEASE_TAG to the immutable release tag for this build}"
case "$VCODE_RELEASE_TAG" in
    *[!a-zA-Z0-9._-]*|'') echo 'Invalid release tag.' >&2; exit 1 ;;
esac
archive="${1:-dist/VCode-macos-arm64.zip}"
output="${2:-dist/appcast.xml}"
test -f "$archive"
test -s "$SPARKLE_KEY_FILE"
bash scripts/prepare-sparkle-tools.sh
staging="$(mktemp -d "$(pwd)/.build/sparkle-feed.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
cp "$archive" "$staging/VCode-macos-arm64.zip"
.build/sparkle-tools/2.10.0/bin/generate_appcast \
    --ed-key-file "$SPARKLE_KEY_FILE" \
    --download-url-prefix "https://github.com/Liz2Z/vcode/releases/download/$VCODE_RELEASE_TAG/" \
    --link 'https://github.com/Liz2Z/vcode/releases' \
    --maximum-versions 1 --maximum-deltas 0 "$staging"
.build/sparkle-tools/2.10.0/bin/sign_update --verify --ed-key-file "$SPARKLE_KEY_FILE" "$staging/appcast.xml"
mkdir -p "$(dirname "$output")"
cp "$staging/appcast.xml" "$output"
