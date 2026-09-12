#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
node --test tests/browser/*.test.cjs
portable=$(mktemp -d)
trap 'rm -rf "$portable"' EXIT
swiftc "${kit_flags[@]}" -swift-version 6 -warnings-as-errors \
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
out.joinpath('State.swift').write_text('// ControllerState is compiled from the production Switch2Kit target.\n')
s=(base/'Output/WebSocketHub.swift').read_text()
needle='        guard let data = try? JSONSerialization.data(withJSONObject: object)'
assert s.count(needle) == 1
s=s.replace(needle, '        TestJSON.record(object)\n'+needle)
out.joinpath('DemandHub.swift').write_text(s+'\n'+Path('tests/browser/DemandTests.swift').read_text())
PY
swiftc "${kit_flags[@]}" -swift-version 6 -warnings-as-errors "${kit_sources[@]}" \
 tests/output-health/Probe.swift Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
 Sources/FinallyTheControllerWorks/Runtime/BoundedStateMailbox.swift \
 Sources/FinallyTheControllerWorks/Runtime/BrowserBridgeConfiguration.swift \
 "$work/State.swift" Sources/FinallyTheControllerWorks/Output/WebSocketHub.swift \
 tests/browser/BrowserServer.swift -o "$work/browser-server"
python3 tests/browser/websocket_test.py "$work/browser-server"
swiftc "${kit_flags[@]}" -swift-version 6 -warnings-as-errors "${kit_sources[@]}" \
 tests/output-health/Probe.swift Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
 Sources/FinallyTheControllerWorks/Runtime/BoundedStateMailbox.swift \
 Sources/FinallyTheControllerWorks/Runtime/BrowserBridgeConfiguration.swift \
 "$work/State.swift" "$work/DemandHub.swift" -o "$work/browser-demand"
"$work/browser-demand"
