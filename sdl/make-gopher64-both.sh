#!/bin/bash
# make-gopher64-both.sh — assemble Gopher64-Both.app: the official Gopher64
# (with its working netplay secret) + our patched SDL that drives the
# Switch 2 Pro Controller.
#
# Strategy: the official app statically links SDL but ships SDL's official
# SDL3_DYNAMIC_API override hook. We drop our patched libSDL3 inside a fresh
# copy of the bundle and set SDL3_DYNAMIC_API (via LSEnvironment) so the app
# loads OUR SDL at startup. macOS library validation would normally forbid
# loading an outside dylib, so we re-sign the copy ad-hoc without hardened
# runtime. The app's own binary — which holds the netplay credential — is
# only re-signed, never altered, so netplay keeps working.
#
# Nothing here touches the original /Applications/Gopher64.app.
set -euo pipefail

SRC="/Applications/Gopher64.app"
DYLIB="${SDL3_LIBRARY:-$(cd "$(dirname "$0")/.." && pwd)/build/sdl/libSDL3.0.dylib}"
if [ ! -f "$DYLIB" ]; then
    echo "Build the corrected SDL first: bash sdl/build-sdl.sh /path/to/SDL" >&2
    echo "Or set SDL3_LIBRARY to an explicitly selected compatible dylib." >&2
    exit 1
fi
WORK="$(mktemp -d)/Gopher64-Both.app"
DEST="$HOME/Applications/Gopher64-Both.app"
# Portable: @executable_path resolves relative to the bundle no matter where
# it (or which user) it lands on — so the app works after being copied to
# another Mac. dlopen expands @executable_path for the process calling it,
# which is correct for both gopher64 and gopher64-cli (both live in MacOS/).
RUNTIME_DYLIB="@executable_path/../Frameworks/libSDL3.0.dylib"

echo ">> Assembling fresh bundle in scratchpad (avoids app-protection on install dirs)"
rm -rf "$WORK"
mkdir -p "$WORK/Contents/MacOS" "$WORK/Contents/Frameworks"

# Copy the app's pieces. Working in /tmp means these become plain files we
# own and may re-sign, unlike a copy placed directly in ~/Applications.
cp "$SRC/Contents/Info.plist"                 "$WORK/Contents/Info.plist"
cp -R "$SRC/Contents/Resources"               "$WORK/Contents/Resources"
cp "$SRC/Contents/MacOS/gopher64"             "$WORK/Contents/MacOS/gopher64"
cp "$SRC/Contents/MacOS/gopher64-cli"         "$WORK/Contents/MacOS/gopher64-cli" 2>/dev/null || true
cp "$SRC/Contents/Frameworks/libMoltenVK.dylib" "$WORK/Contents/Frameworks/libMoltenVK.dylib"
# Our patched SDL, bundled inside the app.
cp "$DYLIB"                                   "$WORK/Contents/Frameworks/libSDL3.0.dylib"
chmod +x "$WORK/Contents/MacOS/gopher64" "$WORK/Contents/Frameworks/libSDL3.0.dylib"

echo ">> Patching Info.plist: new identity + SDL3_DYNAMIC_API override"
PB=/usr/libexec/PlistBuddy
IP="$WORK/Contents/Info.plist"
# Distinct identity + name so LaunchServices treats it as its own app.
$PB -c "Set :CFBundleIdentifier io.github.gopher64.both" "$IP"
$PB -c "Set :CFBundleName Gopher64-Both" "$IP" 2>/dev/null || $PB -c "Add :CFBundleName string Gopher64-Both" "$IP"
# Point SDL at our patched dylib. LSEnvironment is applied on GUI launch.
$PB -c "Delete :LSEnvironment" "$IP" 2>/dev/null || true
$PB -c "Add :LSEnvironment dict" "$IP"
$PB -c "Add :LSEnvironment:SDL3_DYNAMIC_API string $RUNTIME_DYLIB" "$IP"

echo ">> Re-signing ad-hoc WITHOUT hardened runtime (turns off library validation)"
# Sign inner dylibs first, then BOTH executables, then seal the bundle.
# gopher64-cli is the process that actually runs the game; it inherits
# SDL3_DYNAMIC_API from its parent, so it too must be allowed to load our
# patched SDL — otherwise macOS code-signing enforcement SIGTRAPs it on
# game launch. This was the game-launch crash.
codesign -f -s - --timestamp=none "$WORK/Contents/Frameworks/libSDL3.0.dylib"
codesign -f -s - --timestamp=none "$WORK/Contents/MacOS/gopher64"
codesign -f -s - --timestamp=none "$WORK/Contents/MacOS/gopher64-cli"
# No --deep (it errors on MoltenVK); MoltenVK keeps its own valid signature.
codesign -f -s - --timestamp=none "$WORK"

echo ">> Verifying gopher64-cli no longer has team-id/hardened-runtime signature"
codesign -dv "$WORK/Contents/MacOS/gopher64-cli" 2>&1 | grep -iE "flags|TeamIdentifier" || true

echo ">> Verifying signature has no hardened-runtime flag"
codesign -dv "$WORK" 2>&1 | grep -i "flags" || true

echo ">> Installing to $DEST"
rm -rf "$DEST"
mkdir -p "$HOME/Applications"
mv "$WORK" "$DEST"

echo ">> Done. Built: $DEST"
echo ">> Netplay secret: preserved (app binary only re-signed, not modified)"
echo ">> Controller: driven by bundled patched SDL via SDL3_DYNAMIC_API"
