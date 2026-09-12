#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
base=Path('Sources/GameCubed')
s=(base/'Bluetooth/ControllerSession.swift').read_text()
a=s.index('struct ControllerState:');b=s.index('/// Called on the Bluetooth queue.',a)
Path(sys.argv[1],'State.swift').write_text('import Foundation\n'+s[a:b])
s=(base/'Output/KeyboardMapper.swift').read_text().replace('import CoreGraphics','')
a=s.index('    private static func postKey(')
s=s[:a]+'    private static func postKey(_ spec: KeySpec, _ down: Bool) {}\n}\n'
# Only the actual CGEvent boundary is replaced; ownership/process methods are unchanged.
Path(sys.argv[1],'Keyboard.swift').write_text(s)
PY
swiftc -swift-version 6 \
 Sources/GameCubed/Protocol/Switch2Protocol.swift "$work/State.swift" \
 Sources/GameCubed/Runtime/ControllerConfiguration.swift "$work/Keyboard.swift" \
 tests/runtime/RuntimeTests.swift -o "$work/tests"
"$work/tests"
