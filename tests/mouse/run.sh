#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1]); base = Path('Sources/FinallyTheControllerWorks')
s = (base/'Bluetooth/ControllerSession.swift').read_text()
a = s.index('struct ControllerState:'); b = s.index('/// Called on the Bluetooth queue.', a)
(out/'State.swift').write_text('import Foundation\n' + s[a:b])
# Replace only CoreGraphics with event-posting fakes; retain the actual motion path.
s = (base/'Output/MouseController.swift').read_text().replace('import CoreGraphics', '')
(out/'Mouse.swift').write_text(s)
PY
swiftc -swift-version 5 Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 Sources/FinallyTheControllerWorks/Runtime/ControllerConfiguration.swift \
 "$work/State.swift" "$work/Mouse.swift" tests/mouse/MouseTests.swift -o "$work/check"
"$work/check"
