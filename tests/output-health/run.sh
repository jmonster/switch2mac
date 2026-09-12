#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
 Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
 tests/output-health/PolicyTests.swift -o "$work/policy"
"$work/policy"
python3 - <<'PY'
from pathlib import Path
app=Path('Sources/FinallyTheControllerWorks/FTCWApp.swift').read_text()
view=Path('Sources/FinallyTheControllerWorks/UI/OutputStatusView.swift').read_text()
dashboard=Path('Sources/FinallyTheControllerWorks/UI/DashboardView.swift').read_text()
assert '.disabled(!status.model.hasDirectRumbleTest)' in dashboard
assert 'engine.testRumble(serial: serial)' in dashboard
assert 'engine.testRumble(serial: controller.serial)' in view
assert 'engine.testRumble(player:' not in dashboard + view
assert 'No matching connected controller' in view
assert 'Test preset' in dashboard and 'Rumble is muted.' in dashboard
assert 'id: "output-status"' in app
assert 'Output Status and Capabilities' in app and 'Output Status and Capabilities' in view
assert '.disabled(controller == nil || !OutputCapabilities(model: model, backend: backend).directRumble)' in view
for sink in ('UDPHub','WebSocketHub','NetworkGamepadSink','VirtualHIDSink'):
    assert f'OutputStatusStore.shared.register({sink}())' in app
print('PASS output UI wiring, serial-addressed rumble tests, mute and preset guidance')
PY

# Exercise real production sinks, sharing only existing harness declarations.
python3 - "$work" <<'PY'
from pathlib import Path
import re, sys
out=Path(sys.argv[1]);base=Path('Sources/FinallyTheControllerWorks')
s=(base/'Bluetooth/ControllerSession.swift').read_text()
a=s.index('struct ControllerState:');b=s.index('/// Called on the Bluetooth queue.',a)
(out/'State.swift').write_text('import Foundation\n'+s[a:b])
for kind, source, fixture in [('UDP','UDPHub','tests/udp/UDPTests.swift'),('NETPAD','NetworkGamepadSink','tests/retroarch/NetworkTests.swift')]:
    s=(base/f'Output/{source}.swift').read_text()
    if sys.platform!='darwin':
        s=s.replace('import Darwin','import Glibc').replace('SOCK_DGRAM,','Int32(SOCK_DGRAM.rawValue),')
    (out/f'{kind}.swift').write_text(s)
    (out/f'{kind}Types.swift').write_text(Path(fixture).read_text().split('@main')[0])
PY
for kind in UDP NETPAD; do
  swiftc -swift-version 5 -D "HEALTH_$kind" \
    Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
    Sources/FinallyTheControllerWorks/Runtime/BoundedStateMailbox.swift \
    Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
    "$work/State.swift" "$work/$kind.swift" "$work/${kind}Types.swift" \
    tests/output-health/Probe.swift tests/output-health/SinkTests.swift -o "$work/$kind"
  "$work/$kind"
done

if [ "$(uname -s)" = Darwin ]; then
  swiftc -swift-version 6 -warnings-as-errors \
    Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
    Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
    Sources/FinallyTheControllerWorks/UI/OutputStatusStore.swift \
    tests/output-health/StoreTests.swift -o "$work/store"
  "$work/store"
fi
