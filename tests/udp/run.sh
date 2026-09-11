#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import os,re,sys
out=Path(sys.argv[1])
s=Path(os.environ.get('UDP_SOURCE','Sources/FinallyTheControllerWorks/Output/UDPHub.swift')).read_text()
s=re.sub(r'\bprivate\s+', '', s)
if sys.platform != 'darwin':
    s=s.replace('import Darwin','import Glibc\nimport CoreFoundation').replace('SOCK_DGRAM,','Int32(SOCK_DGRAM.rawValue),')
out.joinpath('UDPHub.swift').write_text(s)
s=Path('Sources/FinallyTheControllerWorks/Bluetooth/ControllerSession.swift').read_text()
a=s.index('struct ControllerState:'); b=s.index('/// Called on the Bluetooth queue.',a)
out.joinpath('State.swift').write_text('import Foundation\n'+s[a:b])
PY
swiftc -swift-version 5 Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 tests/output-health/Probe.swift Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
 Sources/FinallyTheControllerWorks/Runtime/BoundedStateMailbox.swift \
 "$work/State.swift" "$work/UDPHub.swift" tests/udp/UDPTests.swift -o "$work/test"
"$work/test" "${UDP_CASE:-all}"
if [ "${UDP_CASE:-all}" = all ]; then
  "$work/test" lifecycle
  "$work/test" late-bind
fi
