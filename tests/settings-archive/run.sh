#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work/State.swift" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text('// ControllerState is compiled from the production Switch2Kit target.\n')
PY
swiftc "${kit_flags[@]}" -swift-version 6 -warnings-as-errors \
  "${kit_sources[@]}" \
  "$work/State.swift" \
  Sources/FinallyTheControllerWorks/Runtime/ControllerConfiguration.swift \
  Sources/FinallyTheControllerWorks/Runtime/SettingsArchive.swift \
  tests/settings-archive/SettingsArchiveTests.swift -o "$work/settings-tests"
"$work/settings-tests"
