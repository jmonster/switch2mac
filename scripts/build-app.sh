#!/bin/bash
# build-app.sh — build FinallyTheControllerWorks.app from the Swift package.
#
# Usage:
#   ./scripts/build-app.sh                 # ad-hoc signed (no virtual HID)
#   SIGN_IDENTITY="Developer ID Application: ..." \
#   PROVISIONING_PROFILE=path/to.provisionprofile \
#     ./scripts/build-app.sh               # full signing incl. HID entitlement
#
# Output: build/Finally the Controller Works.app

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Finally the Controller Works"
EXE=FinallyTheControllerWorks
OUT="build/$APP_NAME.app"

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

if [ -n "${SIGN_IDENTITY:-}" ]; then
    if [ -n "${PROVISIONING_PROFILE:-}" ]; then
        # Full build: profile-gated HID entitlement → system-wide virtual pads.
        cp "$PROVISIONING_PROFILE" "$OUT/Contents/embedded.provisionprofile"
        codesign --force --options runtime --timestamp \
            --entitlements Resources/entitlements-dev.plist \
            --sign "$SIGN_IDENTITY" "$OUT"
        echo "Signed with: $SIGN_IDENTITY (virtual HID enabled)"
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
