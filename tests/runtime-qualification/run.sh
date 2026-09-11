#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 Sources/FinallyTheControllerWorks/Runtime/RuntimeCompatibility.swift \
 tests/runtime-qualification/RuntimeTests.swift -o "$work/check"
"$work/check"
python3 - <<'PY'
from pathlib import Path
base = Path('Sources/FinallyTheControllerWorks')
entry = (base/'Runtime/ApplicationEntry.swift').read_text()
assert entry.index('contains("--runtime-check")') < entry.index('FTCWApp.main()')
assert '@main' not in (base/'FTCWApp.swift').read_text()
assert 'BridgeEngine(' not in entry and 'UserDefaults' not in entry
print('PASS isolated packaged-app probe entry wiring')
PY
