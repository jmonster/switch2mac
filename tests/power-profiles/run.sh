#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work/Session.swift" <<'PY'
from pathlib import Path
import re, sys
source=Path('Sources/FinallyTheControllerWorks/Bluetooth/ControllerSession.swift').read_text()
source=re.sub(r'^import (CoreBluetooth|IOBluetooth)$', '', source, flags=re.M)
source=re.sub(r'\b(?:fileprivate|private)(?:\(set\))?\s+', '', source)
Path(sys.argv[1]).write_text('import CoreFoundation\n'+source)
PY
swiftc -swift-version 5 Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 "$work/Session.swift" tests/session/FrameworkFakes.swift tests/power-profiles/Tests.swift -o "$work/test"
env -u SWITCH2MAC_EXPERIMENTAL_SENSORS -u SWITCH2MAC_ACKNOWLEDGE_UNQUALIFIED_POWER "$work/test" compatibility
for profile in compatibility gamepad motion pointer; do
  SWITCH2MAC_EXPERIMENTAL_SENSORS="$profile" SWITCH2MAC_ACKNOWLEDGE_UNQUALIFIED_POWER=1 "$work/test" "$profile"
done
SWITCH2MAC_EXPERIMENTAL_SENSORS=gamepad SWITCH2MAC_ACKNOWLEDGE_UNQUALIFIED_POWER=0 "$work/test" compatibility
SWITCH2MAC_EXPERIMENTAL_SENSORS=0xFF SWITCH2MAC_ACKNOWLEDGE_UNQUALIFIED_POWER=1 "$work/test" compatibility
