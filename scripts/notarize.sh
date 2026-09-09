#!/bin/bash
# Explicit fork signing/notarization only. No inherited identity, credential
# profile, update feed or release publication. Read docs/fork-identity.md first.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Supply your own Developer ID signing identity}"
: "${NOTARY_KEYCHAIN_PROFILE:?Supply your own notarytool keychain profile}"
APP="build/Finally the Controller Works (jmonster).app"
ZIP="build/switch2mac-jmonster.zip"

bash scripts/build-app.sh
codesign --verify --strict "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarized bundle: $APP"
echo "Archive: $ZIP"
echo "No update feed, tag, or release was generated or published."
