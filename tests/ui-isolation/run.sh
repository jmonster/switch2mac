#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "$(uname -s)" = Darwin ] || exit 0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work/KeySpec.swift" <<'PY'
from pathlib import Path
import sys
s=Path('Sources/FinallyTheControllerWorks/Runtime/ControllerConfiguration.swift').read_text()
a=s.index('struct KeySpec:');b=s.index('/// Queue-confined', a)
Path(sys.argv[1]).write_text('import Foundation\n'+s[a:b])
PY
swiftc -swift-version 6 -warnings-as-errors \
 "$work/KeySpec.swift" Sources/FinallyTheControllerWorks/UI/KeyCaptureSession.swift \
 tests/ui-isolation/KeyCaptureTests.swift -o "$work/check"
"$work/check"
