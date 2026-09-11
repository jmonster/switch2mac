#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 tests/release/test_release.py
if [ "$(uname -s)" = Darwin ]; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/Fixture.app/Contents/MacOS"
  printf 'int main(void) { return 0; }\n' > "$work/main.c"
  clang "$work/main.c" -o "$work/Fixture.app/Contents/MacOS/App"
  python3 - "$work/Fixture.app" <<'PY'
from pathlib import Path
import plistlib, sys
app = Path(sys.argv[1])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'io.github.jmonster.switch2mac','CFBundleExecutable':'App',
    'CFBundlePackageType':'APPL','CFBundleVersion':'1',
    'FTCWSourceRevision':'a'*40,'FTCWSourceDirty':False}))
PY
  codesign --force --sign - "$work/Fixture.app"
  python3 - "$work/Fixture.app" <<'PY'
from pathlib import Path
import importlib.util, sys
spec = importlib.util.spec_from_file_location('release', 'scripts/notarize-release.py')
release = importlib.util.module_from_spec(spec); spec.loader.exec_module(release)
try:
    release.verify_app(Path(sys.argv[1]), 'ABCDEFGHIJ', 'a'*40, release.command)
except release.ReleaseError as error:
    assert 'Developer ID Application' in str(error)
else:
    raise AssertionError('Actual ad-hoc signature was incorrectly accepted as a release')
print('PASS actual macOS ad-hoc signature rejection; no notarization submitted')
PY
fi
