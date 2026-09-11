#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo 'Packaged runtime check requires macOS' >&2; exit 2; }
app=${1:-"build/Finally the Controller Works (jmonster).app"}
output=${2:-build/runtime-qualification.json}
codesign --verify --deep --strict "$app"
python3 - "$app" "$output" <<'PY'
import json, pathlib, platform, plistlib, re, subprocess, sys
app = pathlib.Path(sys.argv[1]).resolve()
with (app/'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
exe = app/'Contents/MacOS'/info['CFBundleExecutable']
result = subprocess.run([str(exe), '--runtime-check'], check=True, capture_output=True, text=True, timeout=20)
probe = json.loads(result.stdout)
assert probe['schema'] == 1 and probe['scope'] == 'packaged-loader-and-protocol'
assert probe['operatingSystem'] == platform.mac_ver()[0]
assert probe['architecture'] == platform.machine()
assert probe['sourceRevision'] == subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
assert probe['sourceDirty'] is False
assert all(probe[key] == 'not-run' for key in ('hardwareQualification', 'gameQualification', 'hidEntitlementQualification'))
# Validate package, bundle and Mach-O metadata, not just what the executable says.
package = pathlib.Path('Package.swift').read_text()
m = re.search(r'\.macOS\(\.v(\d+)\)', package)
assert m, 'Update the validator explicitly when adopting a custom package minimum'
def version(s):
    values = tuple(map(int, s.split('.')))
    return values + (0,) * (3-len(values))
assert version(m.group(1)) == version(info['LSMinimumSystemVersion']) == version(probe['declaredMinimum'])
build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(exe)], text=True)
minimums = re.findall(r'^\s*minos\s+(\S+)', build, re.M)
assert minimums and all(version(s) == version(probe['declaredMinimum']) for s in minimums), build
probe['sdkBuildMetadata'] = build
probe['toolchain'] = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
probe['acceptanceLimit'] = 'Loader/protocol probe only; not GUI, permissions, radio, entitlement or game acceptance; not every OS patch.'
output = pathlib.Path(sys.argv[2]); output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(probe, indent=2, sort_keys=True) + '\n', encoding='utf-8')
print(output.read_text())
PY
