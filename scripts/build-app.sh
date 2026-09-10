#!/bin/bash
# build-app.sh — build FinallyTheControllerWorks.app from the Swift package.
#
# Usage:
#   ./scripts/build-app.sh                 # ad-hoc signed (no virtual HID)
#   SIGN_IDENTITY="Developer ID Application: ..." \
#   PROVISIONING_PROFILE=path/to.provisionprofile \
#   SIGN_ENTITLEMENTS=path/to/fork-entitlements.plist \
#     ./scripts/build-app.sh               # full signing incl. HID entitlement
#
# Output: build/Finally the Controller Works (jmonster).app

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Finally the Controller Works (jmonster)"
EXE=FinallyTheControllerWorks
OUT="build/$APP_NAME.app"

# Never silently sign this fork with the upstream application's entitlements.
if [ -n "${PROVISIONING_PROFILE:-}" ]; then
    : "${SIGN_IDENTITY:?Set your own Developer ID signing identity}"
    : "${SIGN_ENTITLEMENTS:?Provide a fork-specific entitlement plist explicitly}"
    [ -f "$PROVISIONING_PROFILE" ] && [ -f "$SIGN_ENTITLEMENTS" ] || { echo "Signing input missing" >&2; exit 2; }
    PB=/usr/libexec/PlistBuddy
    BUNDLE_ID=$($PB -c 'Print :CFBundleIdentifier' Resources/Info.plist)
    TEAM=$($PB -c 'Print :com.apple.developer.team-identifier' "$SIGN_ENTITLEMENTS")
    APP_ID=$($PB -c 'Print :com.apple.application-identifier' "$SIGN_ENTITLEMENTS")
    [ -n "$TEAM" ] && [ "$APP_ID" = "$TEAM.$BUNDLE_ID" ] || { echo "Entitlements do not identify this fork" >&2; exit 2; }
fi

swift build -c release

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp ".build/release/$EXE" "$OUT/Contents/MacOS/$EXE"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
        "$OUT/Contents/Info.plist" 2>/dev/null || true
fi

# Keep setup resources with the binary; never install the extension automatically.
mkdir -p "$OUT/Contents/Resources/BrowserExtension"
cp browser/extension/manifest.json browser/extension/*.js "$OUT/Contents/Resources/BrowserExtension/"
REVISION=$(git rev-parse HEAD)
DIRTY=false
[ -z "$(git status --porcelain --untracked-files=normal -- Sources Resources browser/extension scripts Package.swift)" ] || DIRTY=true
/usr/libexec/PlistBuddy -c "Add :FTCWSourceRevision string $REVISION" "$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FTCWSourceDirty bool $DIRTY" "$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FTCWBuildArchitecture string $(uname -m)" "$OUT/Contents/Info.plist"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    if [ -n "${PROVISIONING_PROFILE:-}" ]; then
        # Full build: profile-gated HID entitlement → system-wide virtual pads.
        cp "$PROVISIONING_PROFILE" "$OUT/Contents/embedded.provisionprofile"
        codesign --force --options runtime --timestamp \
            --entitlements "$SIGN_ENTITLEMENTS" \
            --sign "$SIGN_IDENTITY" "$OUT"
        echo "Signed with: $SIGN_IDENTITY (supplied profile; runtime entitlement approval still required)"
    else
        # Developer ID without profile: notarizable, UDP/SDL path only.
        # (Signing the restricted entitlement without an embedded profile
        # would make macOS kill the app at launch.)
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$OUT"
        echo "Signed with: $SIGN_IDENTITY (no profile: virtual HID disabled)"
    fi
else
    codesign --force --sign - "$OUT"
    echo "Ad-hoc signed (virtual HID disabled; UDP/SDL path active)"
fi

echo "Built: $OUT"
