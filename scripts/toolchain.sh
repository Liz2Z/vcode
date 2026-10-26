#!/bin/bash
# Source this file; selecting a toolchain changes this process only, never xcode-select.
vcode_toolchain_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$vcode_toolchain_root/.ci/toolchain.env"

vcode_select_xcode() {
    local vcode_candidate vcode_version vcode_build vcode_details
    local vcode_selected=""
    for vcode_candidate in \
        "/Applications/Xcode_${VCODE_XCODE_VERSION}.app/Contents/Developer" \
        "${DEVELOPER_DIR:-}" \
        "$(/usr/bin/xcode-select -p 2>/dev/null || true)"; do
        [[ -d "$vcode_candidate" ]] || continue
        vcode_details="$(DEVELOPER_DIR="$vcode_candidate" /usr/bin/xcodebuild -version 2>/dev/null)" || continue
        vcode_version="$(printf '%s\n' "$vcode_details" | /usr/bin/awk '/^Xcode / {print $2}')"
        vcode_build="$(printf '%s\n' "$vcode_details" | /usr/bin/awk '/^Build version / {print $3}')"
        if [[ "$vcode_version" == "$VCODE_XCODE_VERSION" && "$vcode_build" == "$VCODE_XCODE_BUILD" ]]; then
            vcode_selected="$vcode_candidate"
            break
        fi
    done
    if [[ -z "$vcode_selected" ]]; then
        printf 'Xcode %s (%s) is required by .ci/toolchain.env; no matching installation was found.\n' "$VCODE_XCODE_VERSION" "$VCODE_XCODE_BUILD" >&2
        return 1
    fi
    export DEVELOPER_DIR="$vcode_selected"
}

vcode_verify_xcode() {
    local vcode_swift vcode_sdk
    [[ "$(/usr/bin/uname -m)" == arm64 ]] || { echo 'The shared build/test baseline requires macOS arm64.' >&2; return 1; }
    vcode_swift="$(/usr/bin/xcrun swift --version | /usr/bin/sed -nE 's/.*Apple Swift version ([0-9.]+).*/\1/p')"
    vcode_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
    [[ "$vcode_swift" == "$VCODE_SWIFT_VERSION" ]] || { printf 'Swift %s required; found %s.\n' "$VCODE_SWIFT_VERSION" "$vcode_swift" >&2; return 1; }
    [[ "$vcode_sdk" == "$VCODE_MACOS_SDK_VERSION" ]] || { printf 'macOS SDK %s required; found %s.\n' "$VCODE_MACOS_SDK_VERSION" "$vcode_sdk" >&2; return 1; }
}

vcode_verify_node() {
    local vcode_node vcode_npm
    command -v node >/dev/null && command -v npm >/dev/null || { echo 'Install the Node.js version in .ci/toolchain.env before running checks.' >&2; return 1; }
    vcode_node="$(node --version)"
    vcode_npm="$(npm --version)"
    [[ "$vcode_node" == "v$VCODE_NODE_VERSION" ]] || { printf 'Node.js %s required; found %s.\n' "$VCODE_NODE_VERSION" "$vcode_node" >&2; return 1; }
    [[ "$(node -p process.arch)" == arm64 ]] || { echo 'Node.js must be arm64.' >&2; return 1; }
    [[ "$vcode_npm" == "$VCODE_NPM_VERSION" ]] || { printf 'npm %s required; found %s.\n' "$VCODE_NPM_VERSION" "$vcode_npm" >&2; return 1; }
}
