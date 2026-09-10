#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Change visibility/imports only, not method bodies. Fake CoreBluetooth objects
# allow the production session callbacks to run without a radio or permission.
python3 - "$work/ControllerSession.swift" <<'PY'
from pathlib import Path
import os, re, sys
source = Path(os.environ.get('SESSION_SOURCE', 'Sources/FinallyTheControllerWorks/Bluetooth/ControllerSession.swift')).read_text()
source = re.sub(r'^import (CoreBluetooth|IOBluetooth)$', '', source, flags=re.M)
source = re.sub(r'\b(?:fileprivate|private)(?:\(set\))?\s+', '', source)
Path(sys.argv[1]).write_text('import CoreFoundation\n' + source)
PY
swiftc -swift-version 5 \
  Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
  "$work/ControllerSession.swift" tests/session/FrameworkFakes.swift \
  tests/session/SessionTests.swift -o "$work/session-tests"
"$work/session-tests" "${SESSION_CASE:-all}"

swiftc -swift-version 5 \
  Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
  "$work/ControllerSession.swift" tests/session/FrameworkFakes.swift \
  tests/session/FlowTests.swift -o "$work/flow-tests"
"$work/flow-tests" "${SESSION_CASE:-all}"
