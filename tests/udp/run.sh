#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
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
out.joinpath('State.swift').write_text('// ControllerState is compiled from the production Switch2Kit target.\n')
PY
swiftc "${kit_flags[@]}" -swift-version 5 "${kit_sources[@]}" \
 tests/output-health/Probe.swift Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
 Sources/FinallyTheControllerWorks/Runtime/BoundedStateMailbox.swift \
 "$work/State.swift" "$work/UDPHub.swift" tests/udp/UDPTests.swift -o "$work/test"
"$work/test" "${UDP_CASE:-all}"
if [ "${UDP_CASE:-all}" = all ]; then
  "$work/test" lifecycle
  "$work/test" late-bind
fi
