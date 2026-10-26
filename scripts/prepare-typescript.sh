#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# npm is a build-time downloader only. Launch the platform binary directly;
# its adjacent lib.*.d.ts files are also needed by the language service.
case "$(uname -m)" in
    arm64) ts_arch=arm64 ;;
    x86_64) ts_arch=x64 ;;
    *) echo 'Unsupported TypeScript architecture.' >&2; exit 1 ;;
esac
ts_package="Tools/TypeScript/node_modules/@typescript/typescript-darwin-$ts_arch"
ts_version="$(/usr/bin/plutil -extract dependencies.typescript raw -o - Tools/TypeScript/package.json)"
if [[ ! -x "$ts_package/lib/tsc" ]] || [[ "$("$ts_package/lib/tsc" --version)" != "Version $ts_version" ]]; then
    npm ci --prefix Tools/TypeScript --ignore-scripts --registry=https://registry.npmjs.org --no-audit --no-fund
fi
test -x "$ts_package/lib/tsc"
test "$("$ts_package/lib/tsc" --version)" = "Version $ts_version"
mkdir -p .build/typescript-runtime
rm -rf .build/typescript-runtime/TypeScript
cp -R "$ts_package/lib" .build/typescript-runtime/TypeScript
