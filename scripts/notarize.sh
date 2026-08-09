#!/bin/bash
# notarize.sh — build, sign, notarize, and staple the app for distribution.
#
# Prerequisites (one-time):
#   1. A Developer ID Application certificate in the login keychain
#      (already installed for this project).
#   2. An app-specific password from https://account.apple.com
#      (Sign-In & Security → App-Specific Passwords), stored in the keychain:
#         xcrun notarytool store-credentials ftcw-notary \
#             --apple-id "peterksharma1@gmail.com" \
#             --team-id 4BA4S6WKX7 \
#             --password "<app-specific-password>"
#
# Then just run: ./scripts/notarize.sh
#
# Result: build/Finally the Controller Works.app is notarized + stapled, and
# build/FinallyTheControllerWorks.zip is ready to distribute.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Finally the Controller Works.app"
ZIP="build/FinallyTheControllerWorks.zip"
IDENTITY="Developer ID Application: Peter Sharma (4BA4S6WKX7)"
KEYCHAIN_PROFILE="ftcw-notary"

echo "==> Building signed app"
SIGN_IDENTITY="$IDENTITY" ./scripts/build-app.sh

echo "==> Zipping for submission"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (this takes a few minutes)"
xcrun notarytool submit "$ZIP" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Re-zipping the stapled app for distribution"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Done. Distributable, notarized build: $ZIP"
