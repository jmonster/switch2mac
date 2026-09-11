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

swiftc -swift-version 6 -warnings-as-errors Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 Sources/FinallyTheControllerWorks/Runtime/SensorProfileReport.swift tests/power-profiles/ReportTests.swift -o "$work/report"
env -u SWITCH2MAC_EXPERIMENTAL_SENSORS -u SWITCH2MAC_ACKNOWLEDGE_UNQUALIFIED_POWER "$work/report" compatibility
for profile in compatibility gamepad motion pointer; do
  SWITCH2MAC_EXPERIMENTAL_SENSORS="$profile" SWITCH2MAC_ACKNOWLEDGE_UNQUALIFIED_POWER=1 "$work/report" "$profile"
done
SWITCH2MAC_EXPERIMENTAL_SENSORS=motion SWITCH2MAC_ACKNOWLEDGE_UNQUALIFIED_POWER=0 "$work/report" compatibility
SWITCH2MAC_EXPERIMENTAL_SENSORS=invalid SWITCH2MAC_ACKNOWLEDGE_UNQUALIFIED_POWER=1 "$work/report" compatibility
python3 - <<'PYCODE'
from pathlib import Path
entry = Path('Sources/FinallyTheControllerWorks/Runtime/ApplicationEntry.swift').read_text()
assert entry.index('contains("--sensor-profile")') < entry.index('FTCWApp.main()')
assert 'BridgeEngine(' not in entry and 'UserDefaults' not in entry
print('PASS side-effect-free profile command precedes application construction')
PYCODE
