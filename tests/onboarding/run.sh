#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
  Sources/FinallyTheControllerWorks/Runtime/OutputSetupPath.swift \
  tests/onboarding/OutputSetupTests.swift -o "$work/setup-tests"
"$work/setup-tests"
python3 - <<'PY'
from pathlib import Path
import re
base = Path('Sources/FinallyTheControllerWorks')
app = (base/'FTCWApp.swift').read_text()
tour = (base/'UI/AboutAndOnboarding.swift').read_text()
# A renamed window scene must not silently strand a setup action.
for target in re.findall(r'show\("([a-z-]+)"\)', tour):
    assert f'id: "{target}"' in app, f'Unknown onboarding window: {target}'
print('PASS onboarding window destinations')
PY
