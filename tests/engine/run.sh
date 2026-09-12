#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
prepare_session_sources "$work"
python3 tests/support/prepare-sources.py transport "$work"
for suite in tests/engine/EngineTests.swift tests/discovery/EngineTests.swift tests/engine/RetryRegression.swift tests/engine/RetryTests.swift; do
  swiftc -swift-version 5 "${kit_flags[@]}" "${kit_session_sources[@]}" \
    "$work/ControllerTransport.swift" "$work/DiscoveryPolicy.swift" tests/engine/Boundary.swift \
    "$suite" -o "$work/test"
  "$work/test"
done
