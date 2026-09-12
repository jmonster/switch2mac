#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
prepare_session_sources "$work"
python3 tests/support/prepare-sources.py rumble "$work"
swiftc -swift-version 5 "${kit_flags[@]}" "${kit_session_sources[@]}" \
  Sources/FinallyTheControllerWorks/Runtime/ControllerConfiguration.swift \
  "$work/RumbleEngine.swift" tests/rumble/RumbleTests.swift -o "$work/rumble"
"$work/rumble"
