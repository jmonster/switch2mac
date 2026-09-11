#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
node --test tests/browser/*.test.cjs
portable=$(mktemp -d)
trap 'rm -rf "$portable"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
 Sources/FinallyTheControllerWorks/Runtime/BrowserBridgeConfiguration.swift \
 tests/browser/ConfigurationTests.swift -o "$portable/config"
"$portable/config"
[ "$(uname -s)" = Darwin ] || exit 0
work=$(mktemp -d)
trap 'rm -rf "$work" "$portable"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1]);base=Path('Sources/FinallyTheControllerWorks')
s=(base/'Bluetooth/ControllerSession.swift').read_text()
a=s.index('struct ControllerState:');b=s.index('/// Called on the Bluetooth queue.',a)
out.joinpath('State.swift').write_text('import Foundation\n'+s[a:b])
s=(base/'Output/WebSocketHub.swift').read_text()
needle='        guard let data = try? JSONSerialization.data(withJSONObject: object)'
assert s.count(needle) == 1
s=s.replace(needle, '        TestJSON.record(object)\n'+needle)
out.joinpath('DemandHub.swift').write_text(s+'\n'+Path('tests/browser/DemandTests.swift').read_text())
PY
swiftc -swift-version 6 -warnings-as-errors Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 tests/output-health/Probe.swift Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
 Sources/FinallyTheControllerWorks/Runtime/BoundedStateMailbox.swift \
 Sources/FinallyTheControllerWorks/Runtime/BrowserBridgeConfiguration.swift \
 "$work/State.swift" Sources/FinallyTheControllerWorks/Output/WebSocketHub.swift \
 tests/browser/BrowserServer.swift -o "$work/browser-server"
python3 tests/browser/websocket_test.py "$work/browser-server"
swiftc -swift-version 6 -warnings-as-errors Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 tests/output-health/Probe.swift Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
 Sources/FinallyTheControllerWorks/Runtime/BoundedStateMailbox.swift \
 Sources/FinallyTheControllerWorks/Runtime/BrowserBridgeConfiguration.swift \
 "$work/State.swift" "$work/DemandHub.swift" -o "$work/browser-demand"
"$work/browser-demand"
