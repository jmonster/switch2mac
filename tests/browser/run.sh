#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
node --test tests/browser/*.test.cjs
[ "$(uname -s)" = Darwin ] || exit 0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1]);base=Path('Sources/FinallyTheControllerWorks')
s=(base/'Bluetooth/ControllerSession.swift').read_text()
a=s.index('struct ControllerState:');b=s.index('/// Called on the Bluetooth queue.',a)
out.joinpath('State.swift').write_text('import Foundation\n'+s[a:b])
PY
swiftc -swift-version 6 -warnings-as-errors Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 Sources/FinallyTheControllerWorks/Runtime/BoundedStateMailbox.swift \
 "$work/State.swift" Sources/FinallyTheControllerWorks/Output/WebSocketHub.swift \
 tests/browser/BrowserServer.swift -o "$work/browser-server"
python3 tests/browser/websocket_test.py "$work/browser-server"
