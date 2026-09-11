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
# Use real geometry on macOS and fake only event creation/posting. Linux uses
# Foundation's geometry implementation; the production motion path is unchanged.
s = (base/'Output/MouseController.swift').read_text().replace('import CoreGraphics', '#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif')
(out/'Mouse.swift').write_text(s)
(out/'Tests.swift').write_text('#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n' + Path('tests/mouse/MouseTests.swift').read_text())
PY
swiftc -swift-version 5 Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 Sources/FinallyTheControllerWorks/Runtime/ControllerConfiguration.swift \
 "$work/State.swift" "$work/Mouse.swift" "$work/Tests.swift" -o "$work/check"
"$work/check"
