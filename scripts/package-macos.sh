#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-dist/VCode.app}"
output="${2:-dist}"
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Packaging requires macOS.' >&2
    exit 1
fi
if [[ ! -d "$app" ]]; then
    echo "App not found: $app. Run bash scripts/build.sh first." >&2
    exit 1
fi

# Check both native executables so an Intel Node cannot enter an arm64 package.
for executable in "$app/Contents/MacOS/VCode" "$app/Contents/Resources/Runtime/node"; do
    if [[ "$(/usr/bin/lipo -archs "$executable")" != arm64 ]]; then
        echo "Expected an arm64 executable: $executable" >&2
        exit 1
    fi
done
test "$("$app/Contents/Resources/Runtime/node" -p 'process.arch')" = arm64
test -f "$app/Contents/Resources/TypeScript/node_modules/typescript-language-server/lib/cli.mjs"
test -f "$app/Contents/Resources/TypeScript/node_modules/typescript/lib/tsserver.js"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"

mkdir -p "$output"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$output/VCode-macos-arm64.zip"

staging="$(mktemp -d "${TMPDIR:-/tmp}/vcode-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$app" "$staging/VCode.app"
ln -s /Applications "$staging/Applications"
/usr/bin/hdiutil create -volname VCode -srcfolder "$staging" -format UDZO -ov "$output/VCode-macos-arm64.dmg"

(
    cd "$output"
    /usr/bin/shasum -a 256 VCode-macos-arm64.zip VCode-macos-arm64.dmg > SHA256SUMS.txt
)
printf 'Packaged arm64 ZIP and DMG in %s\n' "$output"
