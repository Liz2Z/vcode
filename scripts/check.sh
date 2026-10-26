#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh

# Each run has independent application storage; never consume the developer's session.
vcode_results="${VCODE_CHECK_RESULTS_DIR:-$PWD/.build/check-results/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
[[ "$vcode_results" == /* ]] || { echo 'VCODE_CHECK_RESULTS_DIR must be absolute.' >&2; exit 1; }
umask 077
mkdir -p "$vcode_results"
vcode_results="$(cd "$vcode_results" && pwd)"
for vcode_report in check.log environment.txt swift-test.log result.txt; do
    [[ ! -e "$vcode_results/$vcode_report" ]] || { printf 'Reports already exist in %s; choose a fresh VCODE_CHECK_RESULTS_DIR.\n' "$vcode_results" >&2; exit 1; }
done
vcode_storage="$(mktemp -d "$vcode_results/storage.XXXXXX")"
export XDG_STATE_HOME="$vcode_storage/state"
export XDG_CONFIG_HOME="$vcode_storage/config"
export XDG_DATA_HOME="$vcode_storage/data"
export XDG_CACHE_HOME="$vcode_storage/cache"
trap 'vcode_check_status=$?; printf "exit_code=%s\n" "$vcode_check_status" > "$vcode_results/result.txt"' EXIT
exec > >(tee "$vcode_results/check.log") 2>&1

printf 'Check reports: %s\n' "$vcode_results"
vcode_select_xcode
vcode_verify_xcode
vcode_verify_node
{
    /usr/bin/sw_vers
    /usr/bin/uname -m
    printf 'DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
    /usr/bin/xcodebuild -version
    /usr/bin/xcrun swift --version
    printf 'macOS SDK: '; /usr/bin/xcrun --sdk macosx --show-sdk-version
    printf 'Node.js: '; node --version
    printf 'npm: '; npm --version
    /usr/bin/git --version
    printf 'Commit: '; /usr/bin/git rev-parse HEAD
} | tee "$vcode_results/environment.txt"

npm ci --prefix Tools/TypeScript --ignore-scripts --registry=https://registry.npmjs.org --no-audit --no-fund
bash scripts/prepare-typescript.sh
bash scripts/prepare-ripgrep.sh
export VCODE_LSP_RESOURCES="$PWD/.build/typescript-runtime"
/usr/bin/xcrun swift test --configuration debug --no-parallel 2>&1 | tee "$vcode_results/swift-test.log"
