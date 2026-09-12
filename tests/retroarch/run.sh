#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import os,re,sys
out=Path(sys.argv[1]);base=Path('Sources/FinallyTheControllerWorks')
s=Path(os.environ.get('NETPAD_SOURCE', base/'Output/NetworkGamepadSink.swift')).read_text()
s=re.sub(r'\bprivate\s+', '', s)
if sys.platform != 'darwin':
    s=s.replace('import Darwin', 'import Glibc\nimport CoreFoundation').replace('SOCK_DGRAM,','Int32(SOCK_DGRAM.rawValue),')
out.joinpath('Sink.swift').write_text(s)
out.joinpath('State.swift').write_text('// ControllerState is compiled from the production Switch2Kit target.\n')
PY
swiftc "${kit_flags[@]}" -swift-version 5 "${kit_sources[@]}" \
 tests/output-health/Probe.swift Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift \
 Sources/FinallyTheControllerWorks/Runtime/BoundedStateMailbox.swift \
 "$work/State.swift" "$work/Sink.swift" tests/retroarch/NetworkTests.swift -o "$work/test"
"$work/test" "${NETPAD_CASE:-all}"
