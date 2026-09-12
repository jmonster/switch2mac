#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work/Policy.swift" <<'PY'
from pathlib import Path
import re, sys
s=Path('Sources/GameCubed/Runtime/DiscoveryPolicy.swift').read_text()
Path(sys.argv[1]).write_text(re.sub(r'\bprivate\s+', '', s))
PY
swiftc -swift-version 6 -warnings-as-errors "$work/Policy.swift" tests/discovery/PolicyTests.swift -o "$work/policy"
"$work/policy"
