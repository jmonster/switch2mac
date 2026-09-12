#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import re, sys
out=Path(sys.argv[1]); root=Path('Sources/FinallyTheControllerWorks')
s=(root/'Bluetooth/ControllerSession.swift').read_text()
s=re.sub(r'^import (CoreBluetooth|IOBluetooth)$', '', s, flags=re.M)
s=re.sub(r'\b(?:fileprivate|private)(?:\(set\))?\s+', '', s)
(out/'Session.swift').write_text('import CoreFoundation\n'+s)
s=(root/'Bluetooth/BridgeEngine.swift').read_text()
def extract(marker):
    start=s.index(marker); opening=s.index('{',start); depth=1; end=opening+1
    while depth:
        depth+=(s[end]=='{')-(s[end]=='}'); end+=1
    return re.sub(r'\bprivate\s+', '', s[start:end])
# Test the actual engine routing method and logical-player type. Only the
# surrounding CoreBluetooth/UI lifecycle is replaced; no reimplemented routing.
(out/'Engine.swift').write_text('''import Foundation
final class RumbleTestEngine: @unchecked Sendable {
    let btQueue: DispatchQueue
    var sessions: [Int: ControllerSession] = [:]
    var players: [Int: Logical] = [:]
    init(queue: DispatchQueue) { btQueue = queue }
'''+extract('private struct Logical')+'\n'+extract('func testRumble(serial:')+'\n}\n')
PY
swiftc -swift-version 5 \
 Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 Sources/FinallyTheControllerWorks/Runtime/ControllerConfiguration.swift \
 "$work/Session.swift" tests/session/FrameworkFakes.swift "$work/Engine.swift" \
 tests/rumble/RumbleTests.swift -o "$work/rumble"
"$work/rumble"
