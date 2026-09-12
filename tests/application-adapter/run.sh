#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location('support', 'tests/support/prepare-sources.py')
support = importlib.util.module_from_spec(spec); spec.loader.exec_module(support)
out = Path(sys.argv[1])
root = Path('Sources/FinallyTheControllerWorks')
source = (root/'Bluetooth/BridgeEngine.swift').read_text()
markers = ['func stop(completion:', 'func resume()', 'func setSuspended(',
 'private func updateIdleSweep()', 'private func sweepIdleSessions()', 'private func handlePointerInput(',
 'private func retire(', 'private func resetConnections(', 'private func receiveController(',
 'private func reconcile(', 'private func accept(', 'static func mergeStates(']
body = '\n'.join(support.extract(source, marker) for marker in markers)
body = support.fixture(body).removeprefix('import CoreFoundation\n')
(out/'Engine.swift').write_text(Path('tests/application-adapter/Boundary.swift').read_text()+body+'\n}\n')
for name in ['Switch2KitAdapter', 'Switch2KitStateAdapter']:
    source = (root/f'Runtime/{name}.swift').read_text()
    source = re.sub(r'^import (Switch2Kit|Switch2KitExperimental)$', '', source, flags=re.M)
    source = re.sub(r'^typealias (Switch2|ControllerState) = .*$', '', source, flags=re.M)
    (out/f'{name}.swift').write_text(source)
PY
swiftc -swift-version 6 -warnings-as-errors "${kit_flags[@]}" "${kit_sources[@]}" \
  Sources/FinallyTheControllerWorks/Runtime/ControllerConfiguration.swift \
  Sources/FinallyTheControllerWorks/Runtime/VisualizerMailbox.swift \
  "$work/Switch2KitAdapter.swift" "$work/Switch2KitStateAdapter.swift" "$work/Engine.swift" \
  tests/application-adapter/Tests.swift -o "$work/tests"
"$work/tests"
