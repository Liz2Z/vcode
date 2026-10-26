#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh
vcode_select_xcode
vcode_verify_xcode
bash scripts/prepare-ripgrep.sh

bash scripts/prepare-typescript.sh

/usr/bin/swift build -c release
mkdir -p dist
staging="$(mktemp -d "$(pwd)/dist/.vcode-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/VCode.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/TypeScript"
cp .build/release/VCode "$app/Contents/MacOS/VCode"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${VCODE_BUILD_VERSION:-}" ]]; then
    [[ "$VCODE_BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo 'Invalid build version.' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VCODE_BUILD_VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${VCODE_MARKETING_VERSION:-}" ]]; then
    [[ "$VCODE_MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo 'Invalid marketing version.' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VCODE_MARKETING_VERSION" "$app/Contents/Info.plist"
fi
mkdir -p "$app/Contents/Frameworks"
sparkle=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$sparkle"
/usr/bin/ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Resources/Licenses/Sparkle"
cp .build/checkouts/Sparkle/LICENSE "$app/Contents/Resources/Licenses/Sparkle/"
cp -R .build/typescript-runtime/TypeScript/. "$app/Contents/Resources/TypeScript/"
mkdir -p "$app/Contents/Resources/Licenses/TypeScript"
cp Tools/TypeScript/node_modules/typescript/LICENSE Tools/TypeScript/node_modules/typescript/NOTICE.txt "$app/Contents/Resources/Licenses/TypeScript/"
mkdir -p "$app/Contents/Resources/Runtime"
cp .build/search-runtime/rg "$app/Contents/Resources/Runtime/rg"
mkdir -p "$app/Contents/Resources/Licenses/ripgrep"
cp .build/search-runtime/LICENSE-MIT .build/search-runtime/UNLICENSE .build/search-runtime/COPYING "$app/Contents/Resources/Licenses/ripgrep/"
/usr/bin/swift scripts/MakeIcon.swift "$app/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --deep --sign - "$app"
destination="$(pwd)/dist/VCode.app"
previous="$(pwd)/.build/Previous-VCode.app"
rm -rf "$previous"
if [[ -d "$destination" ]]; then mv "$destination" "$previous"; fi
mv "$app" "$destination"
printf 'Built %s\n' "$destination"
