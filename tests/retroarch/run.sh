#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
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
s=(base/'Bluetooth/ControllerSession.swift').read_text()
a=s.index('struct ControllerState:');b=s.index('/// Called on the Bluetooth queue.',a)
out.joinpath('State.swift').write_text('import Foundation\n'+s[a:b])
PY
swiftc -swift-version 5 Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
 Sources/FinallyTheControllerWorks/Runtime/BoundedStateMailbox.swift \
 "$work/State.swift" "$work/Sink.swift" tests/retroarch/NetworkTests.swift -o "$work/test"
"$work/test" "${NETPAD_CASE:-all}"
