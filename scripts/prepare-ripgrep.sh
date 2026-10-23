#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -m)" in
  arm64) target=aarch64-apple-darwin; checksum=378e973289176ca0c6054054ee7f631a065874a352bf43f0fa60ef079b6ba715 ;;
  x86_64) target=x86_64-apple-darwin; checksum=64811cb24e77cac3057d6c40b63ac9becf9082eedd54ca411b475b755d334882 ;;
  *) echo 'Unsupported ripgrep runtime architecture.' >&2; exit 1 ;;
esac
name="ripgrep-15.1.0-$target"
directory="$(pwd)/.build/search-runtime"
mkdir -p "$directory"
archive="$directory/$name.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 "https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/$name.tar.gz" --output "$archive.download"
  mv "$archive.download" "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | /usr/bin/shasum -a 256 --check
staging="$(mktemp -d "$directory/unpack.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
tar -xzf "$archive" -C "$staging"
cp "$staging/$name/rg" "$directory/rg"
cp "$staging/$name/LICENSE-MIT" "$directory/LICENSE-MIT"
cp "$staging/$name/UNLICENSE" "$directory/UNLICENSE"
cp "$staging/$name/COPYING" "$directory/COPYING"
"$directory/rg" --version
