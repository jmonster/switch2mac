#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Compile real method bodies. Only Apple framework boundaries and visibility
# change, as in the existing session harness; no controller/radio is simulated
# by replacing production decoding, command framing or rumble logic.
python3 - "$work/ControllerSession.swift" <<'PY'
from pathlib import Path
import re, sys
source = Path('Sources/GameCubed/Bluetooth/ControllerSession.swift').read_text()
source = re.sub(r'^import (CoreBluetooth|IOBluetooth)$', '', source, flags=re.M)
source = re.sub(r'\b(?:fileprivate|private)(?:\(set\))?\s+', '', source)
Path(sys.argv[1]).write_text('import CoreFoundation\n' + source)
PY
swiftc -swift-version 5 \
  Sources/GameCubed/Protocol/Switch2Protocol.swift \
  Sources/GameCubed/Runtime/ControllerConfiguration.swift \
  "$work/ControllerSession.swift" tests/session/FrameworkFakes.swift \
  tests/pro-controller/ProControllerTests.swift -o "$work/pro-tests"
"$work/pro-tests"
