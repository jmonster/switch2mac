#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 tests/installer/test_install.py
# Exercise real Mach-O architecture checks and macOS signing on a disposable
# fixture. This is installation acceptance, not SDL/game compatibility.
if [ "$(uname -s)" = Darwin ]; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  src="$work/Original.app"
  mkdir -p "$src/Contents/MacOS" "$src/Contents/Frameworks" "$src/Contents/Resources"
  printf 'int main(void) { return 0; }\n' > "$work/main.c"
  clang "$work/main.c" -o "$src/Contents/MacOS/gopher64"
  cp "$src/Contents/MacOS/gopher64" "$src/Contents/MacOS/gopher64-cli"
  printf 'int fixture(void) { return 0; }\n' > "$work/library.c"
  clang -dynamiclib "$work/library.c" -o "$src/Contents/Frameworks/libMoltenVK.dylib"
  cp "$src/Contents/Frameworks/libMoltenVK.dylib" "$work/SDL.dylib"
  python3 - "$src/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'io.github.switch2mac.install-fixture',
                  'CFBundleExecutable':'gopher64','CFBundleName':'Fixture',
                  'CFBundlePackageType':'APPL','CFBundleVersion':'1'}, stream)
PY
  for file in "$src/Contents/MacOS/"* "$src/Contents/Frameworks/"*; do
    codesign --force --sign - "$file"
  done
  codesign --force --sign - "$src"
  python3 sdl/install_gopher64.py --source "$src" --library "$work/SDL.dylib" --destination "$work/Generated.app"
  python3 sdl/install_gopher64.py --source "$src" --library "$work/SDL.dylib" --destination "$work/Generated.app"
  codesign --verify --deep --strict "$work/Generated.app"
  echo 'PASS actual macOS fixture install, replacement, architecture and signature verification'
fi
