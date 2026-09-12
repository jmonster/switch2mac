#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors Sources/GameCubed/Protocol/Switch2Protocol.swift \
 Sources/GameCubed/Runtime/RuntimeCompatibility.swift \
 tests/runtime-qualification/RuntimeTests.swift -o "$work/check"
"$work/check"
python3 - <<'PY'
from pathlib import Path
base = Path('Sources/GameCubed')
entry = (base/'Runtime/ApplicationEntry.swift').read_text()
assert entry.index('contains("--runtime-check")') < entry.index('GameCubedApp.main()')
assert '@main' not in (base/'GameCubedApp.swift').read_text()
assert 'BridgeEngine(' not in entry and 'UserDefaults' not in entry
print('PASS isolated packaged-app probe entry wiring')
PY
