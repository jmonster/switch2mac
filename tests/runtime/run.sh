#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
base=Path('Sources/FinallyTheControllerWorks')
Path(sys.argv[1],'State.swift').write_text('// ControllerState is compiled from the production Switch2Kit target.\n')
s=(base/'Output/KeyboardMapper.swift').read_text().replace('import CoreGraphics','')
a=s.index('    private static func postKey(')
s=s[:a]+'    private static func postKey(_ spec: KeySpec, _ down: Bool) {}\n}\n'
# Only the actual CGEvent boundary is replaced; ownership/process methods are unchanged.
Path(sys.argv[1],'Keyboard.swift').write_text(s)
PY
swiftc "${kit_flags[@]}" -swift-version 6 \
 "${kit_sources[@]}" "$work/State.swift" \
 Sources/FinallyTheControllerWorks/Runtime/ControllerConfiguration.swift "$work/Keyboard.swift" \
 tests/runtime/RuntimeTests.swift -o "$work/tests"
"$work/tests"
