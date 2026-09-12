#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 tests/support/prepare-sources.py policy "$work"
swiftc -swift-version 6 -warnings-as-errors "${kit_flags[@]}" "${kit_sources[@]}" \
  "$work/ControllerPolicy.swift" "$work/AppPolicy.swift" tests/discovery/PolicyTests.swift -o "$work/policy"
"$work/policy"
