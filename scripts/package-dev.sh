#!/bin/bash
# Package an already-built development app without signing credentials or releases.
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/GameCubed.app"
revision=$(git rev-parse HEAD)
plist="$app/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :FTCWSourceRevision' "$plist")" = "$revision" ] || {
    echo "App does not match this checkout; rebuild it first." >&2; exit 2;
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :FTCWSourceDirty' "$plist")" = false ] || {
    echo "Commit source changes and rebuild before packaging." >&2; exit 2;
}
[ -z "$(git status --porcelain --untracked-files=normal -- Sources Resources browser scripts Package.swift README.md CREDITS.md docs research sdl/*.md sdl/build-sdl.sh)" ] || {
    echo "Source changed since the build; commit and rebuild first." >&2; exit 2;
}
codesign --verify --strict "$app"
for file in manifest.json background.js bridge.js shim.js; do
    cmp "browser/extension/$file" "$app/Contents/Resources/BrowserExtension/$file"
done
documentation="$app/Contents/Resources/Documentation"
for file in README.md CREDITS.md docs/* research/* browser/*.md sdl/*.md sdl/build-sdl.sh; do
    [ -f "$file" ] || continue
    cmp "$file" "$documentation/$file"
done
mkdir -p build/distribution
archive="build/distribution/GameCubed-dev-${revision:0:12}-$(uname -m).zip"
ditto -c -k --keepParent "$app" "$archive"
check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
ditto -x -k "$archive" "$check"
codesign --verify --strict "$check/$(basename "$app")"
cmp "$app/Contents/MacOS/GameCubed" "$check/$(basename "$app")/Contents/MacOS/GameCubed"
(cd build/distribution && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf 'Source: %s\nArchitecture: %s\nDevelopment build; ad-hoc signing is not notarization.\n' "$revision" "$(uname -m)" > "$archive.build-info.txt"
echo "$archive"
