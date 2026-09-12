#!/bin/bash
# Source SwiftPM integration is primary. This creates a real, unsigned dynamic
# framework archive without importing any application resources/signing policy.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
fail() { echo "Switch2Kit XCFramework: $*" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || fail "macOS with full Xcode 26 or newer is required (not the Command Line Tools alone)."
command -v xcodebuild >/dev/null || fail "xcodebuild is unavailable. Select full Xcode using DEVELOPER_DIR."
XCODE_VERSION=$(xcodebuild -version) || fail "The selected developer directory is not a usable Xcode installation."
SWIFT_VERSION=$(xcrun swiftc --version) || fail "The Xcode Swift compiler is unavailable."
python3 - "$XCODE_VERSION" "$SWIFT_VERSION" <<'PY'
import re, sys
xcode = re.search(r'Xcode\s+(\d+)', sys.argv[1])
swift = re.search(r'Swift version (\d+)\.(\d+)', sys.argv[2])
if not xcode or int(xcode[1]) < 26 or not swift or tuple(map(int, swift.groups())) < (6, 2):
    raise SystemExit('Switch2Kit requires Xcode 26+ and Swift 6.2+; select the intended Xcode with DEVELOPER_DIR.')
PY
xcrun --sdk macosx --show-sdk-path >/dev/null || fail "The macOS SDK is unavailable."
mkdir -p "$ROOT/build"
WORK=$(mktemp -d "$ROOT/build/.switch2kit-framework.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PROJECT=$(python3 "$ROOT/scripts/switch2kit/generate-framework-project.py" "$ROOT" "$WORK/project")
ARCHIVE="$WORK/Switch2Kit.xcarchive"
xcodebuild archive -project "$PROJECT" -scheme Switch2Kit -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$WORK/DerivedData" \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO ONLY_ACTIVE_ARCH=NO \
  ARCHS='arm64 x86_64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' | tee "$ROOT/build/Switch2Kit-archive.log"
FRAMEWORK="$ARCHIVE/Products/Library/Frameworks/Switch2Kit.framework"
DSYM="$ARCHIVE/dSYMs/Switch2Kit.framework.dSYM"
[ -d "$FRAMEWORK" ] && [ -d "$DSYM" ] || fail "The archive did not contain a framework and debug symbols."
xcodebuild -create-xcframework -framework "$FRAMEWORK" -debug-symbols "$DSYM" \
  -output "$WORK/Switch2Kit.xcframework"
python3 "$ROOT/scripts/switch2kit/verify-framework.py" "$WORK/Switch2Kit.xcframework"
# Publish only after archive and structural inspection succeed.
rm -rf "$ROOT/build/Switch2Kit.xcframework"
mv "$WORK/Switch2Kit.xcframework" "$ROOT/build/Switch2Kit.xcframework"
{
  printf 'source_revision=%s\n' "$(git -C "$ROOT" rev-parse HEAD)"
  printf 'architectures=arm64 x86_64\nminimum_macos=15.0\nsigning=none\n'
  printf '%s\n%s\n' "$XCODE_VERSION" "$SWIFT_VERSION"
} > "$ROOT/build/Switch2Kit-build.txt"
rm -f "$ROOT/build/Switch2Kit.xcframework.zip"
ditto -c -k --keepParent "$ROOT/build/Switch2Kit.xcframework" "$ROOT/build/Switch2Kit.xcframework.zip"
(cd "$ROOT/build" && shasum -a 256 Switch2Kit.xcframework.zip > Switch2Kit.xcframework.zip.sha256)
echo "Built and inspected: $ROOT/build/Switch2Kit.xcframework (macOS arm64 + x86_64)"
echo 'Redistribution rights are not established; see docs/switch2kit/provenance.md.'
