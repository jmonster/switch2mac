#!/bin/bash
set -euo pipefail
[ "$(uname -s)" = Darwin ] || exit 0
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
  Sources/FinallyTheControllerWorks/Logging/LogStore.swift \
  tests/logging/LogPipelineTests.swift -o "$work/log-tests"
"$work/log-tests"
python3 - "$work" <<'PY'
from pathlib import Path
import os, sys
source = Path(os.environ.get('LOG_SOURCE', 'Sources/FinallyTheControllerWorks/Logging/LogStore.swift')).read_text()
needle = '                try handle.write(contentsOf: data)'
assert source.count(needle) == 1
source = source.replace(needle, '                TestWrites.record(data.count)\n' + needle)
Path(sys.argv[1], 'WriteBatch.swift').write_text(source + '\n' + Path('tests/logging/WriteBatchTests.swift').read_text())
PY
swiftc -parse-as-library -swift-version 6 -warnings-as-errors "$work/WriteBatch.swift" -o "$work/write-tests"
"$work/write-tests"
