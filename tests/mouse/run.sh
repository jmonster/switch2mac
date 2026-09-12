#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1]); base = Path('Sources/FinallyTheControllerWorks')
(out/'State.swift').write_text('// ControllerState is compiled from the production Switch2Kit target.\n')
# Use real geometry on macOS and fake only event creation/posting. Linux uses
# Foundation's geometry implementation; the production motion path is unchanged.
s = (base/'Output/MouseController.swift').read_text().replace('import CoreGraphics', '#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif')
(out/'Mouse.swift').write_text(s)
(out/'Tests.swift').write_text('#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n' + Path('tests/mouse/MouseTests.swift').read_text())
PY
swiftc "${kit_flags[@]}" -swift-version 5 "${kit_sources[@]}" \
 Sources/FinallyTheControllerWorks/Runtime/ControllerConfiguration.swift \
 "$work/State.swift" "$work/Mouse.swift" "$work/Tests.swift" -o "$work/check"
"$work/check"
