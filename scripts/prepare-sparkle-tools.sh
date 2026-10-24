#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep this version aligned with Package.swift. Tools are needed only for releases.
version=2.10.0
checksum=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
destination=".build/sparkle-tools/$version"
if [[ -x "$destination/bin/generate_appcast" && -x "$destination/bin/sign_update" ]]; then exit 0; fi
mkdir -p .build/sparkle-tools
staging="$(mktemp -d "$(pwd)/.build/sparkle-tools/.download.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
    --output "$staging/Sparkle.tar.xz"
printf '%s  %s\n' "$checksum" "$staging/Sparkle.tar.xz" | shasum -a 256 --check
mkdir "$staging/distribution"
tar -xJf "$staging/Sparkle.tar.xz" -C "$staging/distribution"
test -x "$staging/distribution/bin/generate_appcast"
mv "$staging/distribution" "$destination"
