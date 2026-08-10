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

echo "==> Generating appcast.json for the auto-updater"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
# Hosted on GitHub Releases: each release v$VERSION carries the zip and
# appcast.json as assets. The app's feed reads releases/latest/download/
# appcast.json (a stable URL), while the zip URL below is version-pinned
# so an appcast always references its own release's asset.
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/Peterksharma/switch2mac/releases/download}"
cat > build/appcast.json <<EOF
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$DOWNLOAD_BASE/v$VERSION/FinallyTheControllerWorks.zip",
  "sha256": "$SHA",
  "notes": "Version $VERSION.",
  "minimumSystemVersion": "15.0"
}
EOF

echo "Done."
echo "  App:     $APP (notarized + stapled)"
echo "  Zip:     $ZIP"
echo "  Appcast: build/appcast.json"
echo "Publish with:"
echo "  git tag v$VERSION && git push origin main --tags"
echo "  gh release create v$VERSION \"$ZIP\" build/appcast.json \\"
echo "      --title \"v$VERSION\" --notes \"…\""
