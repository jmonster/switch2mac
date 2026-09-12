#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Compile the entire production sink unchanged against a gated CoreHID double.
# Hosted macOS CI separately builds it against Apple's actual framework.
python3 - "$work" <<'PY'
from pathlib import Path
import sys
root = Path('Sources/FinallyTheControllerWorks')
protocol = (root / 'Bluetooth/BridgeEngine.swift').read_text().split('protocol ControllerOutputSink:')[1]
Path(sys.argv[1], 'Types.swift').write_text('import Foundation\nprotocol ControllerOutputSink:' + protocol)
PY
library="$work/libCoreHID.so"
[ "$(uname -s)" != Darwin ] || library="$work/libCoreHID.dylib"
swiftc "${kit_flags[@]}" -swift-version 6 -warnings-as-errors -emit-library -emit-module -module-name CoreHID \
  tests/virtualhid/CoreHID.swift -emit-module-path "$work/CoreHID.swiftmodule" -o "$library"
swiftc "${kit_flags[@]}" -swift-version 6 -warnings-as-errors -I "$work" \
  "${kit_sources[@]}" \
  tests/output-health/Probe.swift Sources/FinallyTheControllerWorks/Runtime/OutputHealth.swift "$work/Types.swift" \
  "${HID_SOURCE:-Sources/FinallyTheControllerWorks/Output/VirtualHID.swift}" \
  tests/virtualhid/LifecycleTests.swift "$library" -Xlinker -rpath -Xlinker "$work" -o "$work/tests"
if [ -n "${HID_CASE:-}" ]; then "$work/tests" "$HID_CASE"; exit; fi
for name in activation order disconnect failure replacement overflow shutdown cancel-activation shutdown-activation stale neutral-failure independent-slots creation-retry layout; do
  "$work/tests" "$name"
done
