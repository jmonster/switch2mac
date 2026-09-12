#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work/State.swift" <<'PY'
from pathlib import Path
import sys
s=Path('Sources/GameCubed/Bluetooth/ControllerSession.swift').read_text()
a=s.index('struct ControllerState:'); b=s.index('/// Called on the Bluetooth queue.', a)
Path(sys.argv[1]).write_text('import Foundation\n'+s[a:b])
PY
swiftc -swift-version 6 -warnings-as-errors \
  Sources/GameCubed/Protocol/Switch2Protocol.swift \
  "$work/State.swift" \
  Sources/GameCubed/Runtime/ControllerConfiguration.swift \
  Sources/GameCubed/Runtime/SettingsArchive.swift \
  tests/settings-archive/SettingsArchiveTests.swift -o "$work/settings-tests"
"$work/settings-tests"
