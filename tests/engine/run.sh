#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import re, sys
root = Path('Sources/FinallyTheControllerWorks')
s = (root/'Bluetooth/ControllerSession.swift').read_text()
s = re.sub(r'^import (CoreBluetooth|IOBluetooth)$', '', s, flags=re.M)
s = re.sub(r'\b(?:fileprivate|private)(?:\(set\))?\s+', '', s)
Path(sys.argv[1], 'Session.swift').write_text('import CoreFoundation\n'+s)
s = (root/'Bluetooth/BridgeEngine.swift').read_text()
def method(marker):
    start = s.index(marker)
    opening = s.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (s[end] == '{') - (s[end] == '}')
        end += 1
    return re.sub(r'\bprivate\s+', '', s[start:end])
# Production lifecycle methods, unchanged; replace CoreBluetooth and unrelated
# UI/output effects only. The full app is built separately against Apple SDKs.
markers = ['func stop(completion:', 'func resume()', 'func setSuspended(',
           'private func owns(', 'private func retire(', 'private func resetConnections(',
           'private func armDeadline(', 'func sessionReady(', 'func sessionFailed(',
           'func sessionDidUpdateState(']
Path(sys.argv[1], 'Engine.swift').write_text(Path('tests/engine/Boundary.swift').read_text()
    + '\n'.join(method(x) for x in markers) + '\n}\n')
PY
swiftc -swift-version 5 Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 "$work/Session.swift" tests/session/FrameworkFakes.swift "$work/Engine.swift" \
 tests/engine/EngineTests.swift -o "$work/check"
"$work/check"
